//! Append-only writes.
//!
//! `fast_append` adds new data files and a new snapshot without rewriting
//! anything that already exists. Row-level deletes, overwrites and MERGE are out
//! of scope for 0.1.0, and are also absent from iceberg-rust itself.
//!
//! Incoming batches are realigned onto the table's own Arrow schema before being
//! written. A data frame exported from R carries no Iceberg field ids, and the
//! Parquet writer needs them, so matching by column name and casting where types
//! differ is what makes an ordinary data frame appendable.

use std::collections::HashMap;
use std::sync::Arc;

use arrow_array::RecordBatch;
use arrow_cast::CastOptions;
use arrow_schema::{Schema as ArrowSchema, SchemaRef};
use extendr_api::prelude::*;
use iceberg::spec::DataFileFormat;
use iceberg::transaction::{ApplyTransactionAction, Transaction};
use iceberg::writer::base_writer::data_file_writer::DataFileWriterBuilder;
use iceberg::writer::file_writer::ParquetWriterBuilder;
use iceberg::writer::file_writer::location_generator::{
    DefaultFileNameGenerator, DefaultLocationGenerator,
};
use iceberg::writer::file_writer::rolling_writer::RollingFileWriterBuilder;
use iceberg::writer::{IcebergWriter, IcebergWriterBuilder};
use parquet::basic::{Compression, GzipLevel, ZstdLevel};
use parquet::file::properties::WriterProperties;

use crate::arrow_bridge::import_reader;
use crate::errors::{RResult, ctx};
use crate::runtime::block_on;
use crate::table::RTable;

fn compression_from(name: &str) -> RResult<Compression> {
    Ok(match name.to_ascii_lowercase().as_str() {
        "zstd" => Compression::ZSTD(ZstdLevel::default()),
        "snappy" => Compression::SNAPPY,
        "gzip" => Compression::GZIP(GzipLevel::default()),
        "lz4" => Compression::LZ4_RAW,
        "uncompressed" | "none" => Compression::UNCOMPRESSED,
        other => {
            return Err(extendr_api::Error::Other(format!(
                "unknown compression {other:?}; expected one of \"zstd\", \
                 \"snappy\", \"gzip\", \"lz4\", \"uncompressed\""
            )));
        }
    })
}

/// Reshape a batch from R onto the table's Arrow schema.
///
/// Columns are matched by name, not by position, so column order in the data
/// frame does not matter. Types are cast when they differ, which is what lets an
/// R `Date` or `POSIXct` land in the right Iceberg type.
fn align_batch(batch: &RecordBatch, target: &SchemaRef) -> RResult<RecordBatch> {
    let incoming = batch.schema();

    // A column the table does not have is almost always a typo or a stale
    // data frame, and silently dropping it would lose data without a word.
    let mut unexpected: Vec<&str> = incoming
        .fields()
        .iter()
        .map(|f| f.name().as_str())
        .filter(|n| target.field_with_name(n).is_err())
        .collect();
    if !unexpected.is_empty() {
        unexpected.sort_unstable();
        let mut expected: Vec<&str> = target.fields().iter().map(|f| f.name().as_str()).collect();
        expected.sort_unstable();
        return Err(extendr_api::Error::Other(format!(
            "the data has {} column(s) that the table does not: {}.\n\
             Table columns are: {}.",
            unexpected.len(),
            unexpected.join(", "),
            expected.join(", ")
        )));
    }

    let mut columns = Vec::with_capacity(target.fields().len());
    for field in target.fields() {
        // Not "which the table requires": a table created from a data frame has
        // every field optional, so naming the Iceberg requiredness here would be
        // wrong in the common case. Every column has to be present regardless,
        // because guessing that an absent one meant NA turns a mistyped name
        // into a silent column of nulls.
        let idx = incoming.index_of(field.name()).map_err(|_| {
            extendr_api::Error::Other(format!(
                "the data is missing column {:?}, which the table has.\n\
                 Every column of the table must appear in the data; supply it as \
                 NA if there is no value for it.",
                field.name()
            ))
        })?;
        let column = batch.column(idx);

        let column = if column.data_type() == field.data_type() {
            column.clone()
        } else {
            // safe = false, deliberately. The default cast replaces a value it
            // cannot represent with a *null*: appending 3e9 to an `int` column,
            // or "abc" to any numeric one, would otherwise write NA over the
            // caller's data and commit it without a word. Refusing the append is
            // the only answer that does not silently lose data.
            arrow_cast::cast_with_options(
                column,
                field.data_type(),
                &CastOptions {
                    safe: false,
                    ..CastOptions::default()
                },
            )
            .map_err(|e| {
                extendr_api::Error::Other(format!(
                    "column {:?} is {} in the data but {} in the table, and the \
                     two cannot be reconciled: {e}",
                    field.name(),
                    column.data_type(),
                    field.data_type()
                ))
            })?
        };
        columns.push(column);
    }

    RecordBatch::try_new(target.clone(), columns)
        .map_err(|e| ctx("the data does not fit the table schema", e))
}

#[extendr]
fn rs_table_append(
    tbl: ExternalPtr<RTable>,
    stream_addr: &str,
    compression: &str,
    property_keys: Vec<String>,
    property_values: Vec<String>,
) -> RResult<ExternalPtr<RTable>> {
    if property_keys.len() != property_values.len() {
        return Err("internal error: snapshot property keys and values differ in length".into());
    }

    let table = &tbl.table;
    let metadata = table.metadata();
    let iceberg_schema = metadata.current_schema().clone();

    // Refused here, before a byte is written. icebergr writes through a plain
    // data-file writer and computes no partition tuples, so every file it
    // produces for a partitioned table carries an empty one -- which iceberg-rust
    // rejects at commit with "Partition value is not compatible with partition
    // type", by which point the Parquet files are already in the warehouse.
    // Nothing then references them, and this package has no maintenance operation
    // to remove them, so a failed append would leave litter behind on every
    // attempt as well as reporting the wrong thing.
    let spec = metadata.default_partition_spec();
    if !spec.fields().is_empty() {
        let by: Vec<String> = spec
            .fields()
            .iter()
            .map(|f| {
                let source = iceberg_schema
                    .field_by_id(f.source_id)
                    .map(|s| s.name.clone())
                    .unwrap_or_else(|| f.source_id.to_string());
                format!("{}({})", f.transform, source)
            })
            .collect();
        return Err(extendr_api::Error::Other(format!(
            "cannot append to {:?}: it is partitioned by {}, and icebergr 0.1.0 \
             writes only to unpartitioned tables.\n\
             An append would have to compute a partition value for every row, \
             which this version does not do. Write to this table with an engine \
             that supports partitioned writes; see icebergr_spec_support().",
            table.identifier().name(),
            by.join(", ")
        )));
    }

    // The Iceberg schema converted to Arrow carries the field-id metadata that
    // the Parquet writer needs.
    let target: SchemaRef = Arc::new(
        ArrowSchema::try_from(iceberg_schema.as_ref())
            .map_err(|e| ctx("could not convert the table schema to Arrow", e))?,
    );

    let mut reader = import_reader(stream_addr)?;
    let mut batches = Vec::new();
    let mut rows: usize = 0;
    for batch in reader.by_ref() {
        let batch = batch.map_err(|e| ctx("could not read the data from R", e))?;
        if batch.num_rows() == 0 {
            continue;
        }
        let batch = align_batch(&batch, &target)?;
        rows += batch.num_rows();
        batches.push(batch);
    }

    // Committing an empty snapshot would add a row to the table's history that
    // says nothing happened. Leave the table untouched instead; the R side
    // reports this.
    if rows == 0 {
        return Ok(ExternalPtr::new(RTable {
            catalog: tbl.catalog.clone(),
            table: table.clone(),
        }));
    }

    let writer_properties = WriterProperties::builder()
        .set_compression(compression_from(compression)?)
        .build();

    let location_generator = DefaultLocationGenerator::new(metadata)
        .map_err(|e| ctx("could not determine where to write data files", e))?;
    // A fresh uuid per append keeps file names from colliding across appends.
    let file_name_generator = DefaultFileNameGenerator::new(
        "icebergr".to_string(),
        Some(uuid::Uuid::new_v4().to_string()),
        DataFileFormat::Parquet,
    );

    let parquet_writer_builder =
        ParquetWriterBuilder::new(writer_properties, iceberg_schema.clone());
    let rolling_writer_builder = RollingFileWriterBuilder::new_with_default_file_size(
        parquet_writer_builder,
        table.file_io().clone(),
        location_generator,
        file_name_generator,
    );
    let data_file_writer_builder = DataFileWriterBuilder::new(rolling_writer_builder);

    let data_files = block_on(async {
        let mut writer = data_file_writer_builder.build(None).await?;
        for batch in batches {
            writer.write(batch).await?;
        }
        writer.close().await
    })
    .map_err(|e| ctx("could not write the data files", e))?;

    let snapshot_properties: HashMap<String, String> =
        property_keys.into_iter().zip(property_values).collect();

    let new_table = block_on(async {
        let tx = Transaction::new(table);
        let mut action = tx.fast_append().add_data_files(data_files);
        if !snapshot_properties.is_empty() {
            action = action.set_snapshot_properties(snapshot_properties);
        }
        let tx = action.apply(tx)?;
        tx.commit(tbl.catalog.as_ref()).await
    })
    .map_err(|e| ctx("could not commit the append", e))?;

    Ok(ExternalPtr::new(RTable {
        catalog: tbl.catalog.clone(),
        table: new_table,
    }))
}

extendr_module! {
    mod write;
    fn rs_table_append;
}
