//! Reads, with pushdown.
//!
//! Pushing the filter and the column projection down into scan planning is the
//! entire performance case for Iceberg over reading raw Parquet: manifests carry
//! per-file statistics, so whole files and whole row groups are eliminated
//! before any bytes are read. Both are therefore applied to the `TableScan`
//! rather than to the result in R.
//!
//! `rs_scan_plan` exposes the planned file list so that pushdown can be
//! *verified* rather than assumed -- a filtered scan should plan fewer files and
//! fewer records, and that is a property worth testing directly.

use std::sync::Arc;

use arrow_schema::{Schema as ArrowSchema, SchemaRef};
use extendr_api::prelude::*;
use futures::TryStreamExt;
use iceberg::arrow::schema_to_arrow_schema;
use iceberg::scan::TableScan;
use iceberg::spec::SchemaRef as IcebergSchemaRef;

use crate::arrow_bridge::{BlockingBatchReader, export_reader};
use crate::errors::{RResult, ctx};
use crate::predicate::build_predicate;
use crate::runtime::block_on;
use crate::table::RTable;

/// Parse a snapshot id and check it against this table's history.
///
/// Catching an unknown id here, with the valid ones listed, is much kinder than
/// letting scan planning fail on a missing manifest list.
fn resolve_snapshot(tbl: &RTable, id: &str) -> RResult<i64> {
    let parsed: i64 = id.trim().parse().map_err(|_| {
        extendr_api::Error::Other(format!(
            "{id:?} is not a valid snapshot id. Snapshot ids are 64-bit \
             integers, passed as strings; see icebergr_snapshots()."
        ))
    })?;

    if tbl.metadata().snapshot_by_id(parsed).is_none() {
        let mut known: Vec<String> = tbl
            .metadata()
            .snapshots()
            .map(|s| s.snapshot_id().to_string())
            .collect();
        known.sort();
        let known = if known.is_empty() {
            "this table has no snapshots yet".to_string()
        } else {
            known.join(", ")
        };
        return Err(extendr_api::Error::Other(format!(
            "snapshot {parsed} is not in this table's history.\nAvailable: {known}"
        )));
    }
    Ok(parsed)
}

/// The schema a predicate should be resolved against.
///
/// When reading an old snapshot, that is the schema *as of* that snapshot, not
/// the current one; otherwise a filter on a since-renamed column would bind to
/// the wrong field.
fn predicate_schema(tbl: &RTable, snapshot: Option<i64>) -> RResult<IcebergSchemaRef> {
    let metadata = tbl.metadata();
    match snapshot {
        Some(id) => {
            let snap = metadata
                .snapshot_by_id(id)
                .ok_or_else(|| extendr_api::Error::Other(format!("unknown snapshot {id}")))?;
            snap.schema(metadata)
                .map_err(|e| ctx("could not read the schema for that snapshot", e))
        }
        None => Ok(metadata.current_schema().clone()),
    }
}

/// Resolve the optional snapshot id R supplied, once, so that everything
/// downstream -- scan planning, predicate binding and the empty-result schema --
/// agrees on which snapshot is being read.
fn resolve_snapshot_opt(tbl: &RTable, snapshot_id: &Option<String>) -> RResult<Option<i64>> {
    match snapshot_id {
        Some(id) => Ok(Some(resolve_snapshot(tbl, id)?)),
        None => Ok(None),
    }
}

#[allow(clippy::too_many_arguments)]
fn configure(
    tbl: &RTable,
    select: &Option<Vec<String>>,
    filter_json: &Option<String>,
    snapshot: Option<i64>,
    batch_size: Option<i32>,
    case_sensitive: bool,
    row_group_filtering: bool,
    row_selection: bool,
) -> RResult<TableScan> {
    let mut builder = tbl.table.scan().with_case_sensitive(case_sensitive);

    // Projection pushdown: only the requested columns are read from Parquet.
    builder = match select {
        Some(cols) if !cols.is_empty() => builder.select(cols.clone()),
        _ => builder.select_all(),
    };

    if let Some(id) = snapshot {
        builder = builder.snapshot_id(id);
    }

    // Predicate pushdown: used to prune manifests, files and row groups.
    if let Some(json) = filter_json {
        let schema = predicate_schema(tbl, snapshot)?;
        let predicate = build_predicate(json, &schema, case_sensitive)?;
        builder = builder.with_filter(predicate);
    }

    if let Some(n) = batch_size
        && n > 0
    {
        builder = builder.with_batch_size(Some(n as usize));
    }

    builder = builder
        .with_row_group_filtering_enabled(row_group_filtering)
        .with_row_selection_enabled(row_selection);

    builder
        .build()
        .map_err(|e| ctx("could not plan the scan", e))
}

/// The schema to report when a scan yields no batches at all.
///
/// Derived from the schema of the snapshot being read, not from the current
/// one: a time-travel read of a table whose columns have since changed must
/// report the columns that snapshot had, whether or not it happens to be empty.
fn fallback_schema(
    tbl: &RTable,
    select: &Option<Vec<String>>,
    snapshot: Option<i64>,
    case_sensitive: bool,
) -> RResult<SchemaRef> {
    let full = schema_to_arrow_schema(predicate_schema(tbl, snapshot)?.as_ref())
        .map_err(|e| ctx("could not convert the Iceberg schema to Arrow", e))?;

    match select {
        Some(cols) if !cols.is_empty() => {
            let mut fields = Vec::with_capacity(cols.len());
            for c in cols {
                // Matched the same way the scan itself matches, so that an empty
                // result does not fail where a non-empty one would have
                // succeeded.
                let f = full
                    .fields()
                    .iter()
                    .find(|f| {
                        if case_sensitive {
                            f.name() == c
                        } else {
                            f.name().eq_ignore_ascii_case(c)
                        }
                    })
                    .ok_or_else(|| {
                        let mut names: Vec<&str> =
                            full.fields().iter().map(|f| f.name().as_str()).collect();
                        names.sort_unstable();
                        extendr_api::Error::Other(format!(
                            "cannot select {c:?}: no such column.\nAvailable columns: {}",
                            names.join(", ")
                        ))
                    })?;
                fields.push(f.clone());
            }
            Ok(Arc::new(ArrowSchema::new(fields)))
        }
        _ => Ok(Arc::new(full)),
    }
}

#[extendr]
#[allow(clippy::too_many_arguments)]
fn rs_scan_to_stream(
    tbl: ExternalPtr<RTable>,
    select: Nullable<Vec<String>>,
    filter_json: Nullable<String>,
    snapshot_id: Nullable<String>,
    batch_size: Nullable<i32>,
    case_sensitive: bool,
    row_group_filtering: bool,
    row_selection: bool,
    stream_addr: &str,
) -> RResult<()> {
    let select = select.into_option();
    let filter_json = filter_json.into_option();
    let snapshot = resolve_snapshot_opt(&tbl, &snapshot_id.into_option())?;

    let scan = configure(
        &tbl,
        &select,
        &filter_json,
        snapshot,
        batch_size.into_option(),
        case_sensitive,
        row_group_filtering,
        row_selection,
    )?;

    let stream = block_on(scan.to_arrow()).map_err(|e| ctx("could not start the scan", e))?;
    let fallback = fallback_schema(&tbl, &select, snapshot, case_sensitive)?;
    let reader = BlockingBatchReader::new(stream, fallback)?;

    export_reader(stream_addr, Box::new(reader))
}

/// The planned file list for a scan, without reading any data.
///
/// This is what makes pushdown observable: compare `sum(record_count)` between a
/// filtered and an unfiltered plan.
#[extendr]
fn rs_scan_plan(
    tbl: ExternalPtr<RTable>,
    select: Nullable<Vec<String>>,
    filter_json: Nullable<String>,
    snapshot_id: Nullable<String>,
    case_sensitive: bool,
) -> RResult<List> {
    let snapshot = resolve_snapshot_opt(&tbl, &snapshot_id.into_option())?;
    let scan = configure(
        &tbl,
        &select.into_option(),
        &filter_json.into_option(),
        snapshot,
        None,
        case_sensitive,
        true,
        true,
    )?;

    let tasks = block_on(async {
        let stream = scan.plan_files().await?;
        stream.try_collect::<Vec<_>>().await
    })
    .map_err(|e| ctx("could not plan the scan", e))?;

    let paths: Vec<String> = tasks.iter().map(|t| t.data_file_path.clone()).collect();
    let records: Vec<Rfloat> = tasks
        .iter()
        .map(|t| match t.record_count {
            // Only populated when the whole file is being read; a split task
            // legitimately has no record count, and NA says so honestly rather
            // than pretending it is zero.
            Some(n) => Rfloat::from(n as f64),
            None => Rfloat::na(),
        })
        .collect();
    let sizes: Vec<f64> = tasks.iter().map(|t| t.file_size_in_bytes as f64).collect();
    let starts: Vec<f64> = tasks.iter().map(|t| t.start as f64).collect();
    let lengths: Vec<f64> = tasks.iter().map(|t| t.length as f64).collect();

    Ok(list!(
        data_file_path = paths,
        record_count = records,
        file_size_in_bytes = sizes,
        start = starts,
        length = lengths
    ))
}

extendr_module! {
    mod scan;
    fn rs_scan_to_stream;
    fn rs_scan_plan;
}
