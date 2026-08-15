//! Table handles and metadata.
//!
//! Snapshot identifiers cross into R as character strings, not numerics.
//! Iceberg assigns them as random 64-bit integers, and R's numeric type carries
//! only 53 bits of integer precision, so a large snapshot id round-tripped
//! through a double would come back subtly wrong -- and then silently select the
//! wrong snapshot. Strings are lossless and, since these are identifiers rather
//! than quantities, cost nothing.

use std::collections::HashMap;
use std::sync::Arc;

use extendr_api::prelude::*;
use iceberg::arrow::arrow_schema_to_schema_auto_assign_ids;
use iceberg::spec::{SchemaRef as IcebergSchemaRef, TableMetadata};
use iceberg::table::Table;
use iceberg::{Catalog, NamespaceIdent, TableCreation, TableIdent};

use crate::arrow_bridge::import_schema;
use crate::errors::{RResult, ctx};
use crate::runtime::block_on;

use crate::catalog::RCatalog;

/// An open table, together with the catalog it came from so that writes and
/// reloads can be committed back.
pub struct RTable {
    pub catalog: Arc<dyn Catalog>,
    pub table: Table,
}

impl RTable {
    pub fn metadata(&self) -> &TableMetadata {
        self.table.metadata()
    }

    /// Parse a snapshot id supplied by R and check it against this table's
    /// history.
    ///
    /// Catching an unknown id here, with the valid ones listed, is much kinder
    /// than letting scan planning fail on a missing manifest list.
    pub fn resolve_snapshot(&self, id: &str) -> RResult<i64> {
        let parsed: i64 = id.trim().parse().map_err(|_| {
            Error::Other(format!(
                "{id:?} is not a valid snapshot id. Snapshot ids are 64-bit \
                 integers, passed as strings; see icebergr_snapshots()."
            ))
        })?;

        if self.metadata().snapshot_by_id(parsed).is_none() {
            let mut known: Vec<String> = self
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
            return Err(Error::Other(format!(
                "snapshot {parsed} is not in this table's history.\nAvailable: {known}"
            )));
        }
        Ok(parsed)
    }

    /// Resolve the optional snapshot id R supplied, once, so that everything
    /// downstream -- the schema, scan planning, predicate binding and the
    /// empty-result schema -- agrees on which snapshot is being read.
    pub fn resolve_snapshot_opt(&self, id: &Option<String>) -> RResult<Option<i64>> {
        match id {
            Some(id) => Ok(Some(self.resolve_snapshot(id)?)),
            None => Ok(None),
        }
    }

    /// The schema in force at `snapshot`, or the current one when it is `None`.
    ///
    /// Every name resolution for a read has to go through this rather than
    /// through `current_schema()`: a filter or a projection on a since-renamed
    /// column would otherwise be checked against columns that snapshot never
    /// had.
    pub fn schema_at(&self, snapshot: Option<i64>) -> RResult<IcebergSchemaRef> {
        let metadata = self.metadata();
        match snapshot {
            Some(id) => {
                let snap = metadata
                    .snapshot_by_id(id)
                    .ok_or_else(|| Error::Other(format!("unknown snapshot {id}")))?;
                snap.schema(metadata)
                    .map_err(|e| ctx("could not read the schema for that snapshot", e))
            }
            None => Ok(metadata.current_schema().clone()),
        }
    }
}

fn table_ident(namespace: Vec<String>, name: &str) -> RResult<TableIdent> {
    let ns = NamespaceIdent::from_vec(namespace).map_err(|e| ctx("invalid namespace", e))?;
    Ok(TableIdent::new(ns, name.to_string()))
}

#[extendr]
fn rs_table_open(
    cat: ExternalPtr<RCatalog>,
    namespace: Vec<String>,
    name: &str,
) -> RResult<ExternalPtr<RTable>> {
    let ident = table_ident(namespace, name)?;
    let table = block_on(cat.inner.load_table(&ident)).map_err(|e| {
        ctx(
            &format!(
                "could not open table {}.{}",
                ident.namespace().as_ref().join("."),
                name
            ),
            e,
        )
    })?;
    Ok(ExternalPtr::new(RTable {
        catalog: cat.inner.clone(),
        table,
    }))
}

#[extendr]
fn rs_table_exists(
    cat: ExternalPtr<RCatalog>,
    namespace: Vec<String>,
    name: &str,
) -> RResult<bool> {
    let ident = table_ident(namespace, name)?;
    block_on(cat.inner.table_exists(&ident)).map_err(|e| ctx("could not check table", e))
}

/// Re-read the table from the catalog, picking up snapshots committed since it
/// was opened.
#[extendr]
fn rs_table_reload(tbl: ExternalPtr<RTable>) -> RResult<ExternalPtr<RTable>> {
    let ident = tbl.table.identifier().clone();
    let table = block_on(tbl.catalog.load_table(&ident))
        .map_err(|e| ctx("could not reload the table", e))?;
    Ok(ExternalPtr::new(RTable {
        catalog: tbl.catalog.clone(),
        table,
    }))
}

/// Create a table whose schema is taken from an Arrow schema exported by R.
///
/// Field ids are assigned automatically, since a data frame has no concept of
/// them.
#[extendr]
fn rs_create_table(
    cat: ExternalPtr<RCatalog>,
    namespace: Vec<String>,
    name: &str,
    schema_addr: &str,
    location: Nullable<String>,
) -> RResult<ExternalPtr<RTable>> {
    let arrow_schema = import_schema(schema_addr)?;
    let schema = arrow_schema_to_schema_auto_assign_ids(&arrow_schema)
        .map_err(|e| ctx("could not convert the R schema to an Iceberg schema", e))?;

    let ns = NamespaceIdent::from_vec(namespace).map_err(|e| ctx("invalid namespace", e))?;

    // location_opt rather than a conditional .location(): TypedBuilder encodes
    // which fields are set in the builder's type, so a chain cannot be built up
    // conditionally.
    let creation = TableCreation::builder()
        .name(name.to_string())
        .schema(schema)
        .location_opt(location.into_option())
        .build();

    let table = block_on(cat.inner.create_table(&ns, creation))
        .map_err(|e| ctx(&format!("could not create table {name:?}"), e))?;

    Ok(ExternalPtr::new(RTable {
        catalog: cat.inner.clone(),
        table,
    }))
}

/// Adopt an existing table by pointing the catalog at its metadata file.
///
/// This is how a warehouse directory on disk becomes visible to an in-process
/// `memory` catalog, which holds no persistent table registry of its own.
#[extendr]
fn rs_register_table(
    cat: ExternalPtr<RCatalog>,
    namespace: Vec<String>,
    name: &str,
    metadata_location: &str,
) -> RResult<ExternalPtr<RTable>> {
    let ident = table_ident(namespace, name)?;
    let table = block_on(
        cat.inner
            .register_table(&ident, metadata_location.to_string()),
    )
    .map_err(|e| ctx(&format!("could not register table {name:?}"), e))?;
    Ok(ExternalPtr::new(RTable {
        catalog: cat.inner.clone(),
        table,
    }))
}

#[extendr]
fn rs_table_identifier(tbl: ExternalPtr<RTable>) -> Vec<String> {
    let ident = tbl.table.identifier();
    let mut out = ident.namespace().as_ref().clone();
    out.push(ident.name().to_string());
    out
}

#[extendr]
fn rs_table_location(tbl: ExternalPtr<RTable>) -> String {
    tbl.metadata().location().to_string()
}

#[extendr]
fn rs_table_format_version(tbl: ExternalPtr<RTable>) -> i32 {
    tbl.metadata().format_version() as i32
}

#[extendr]
fn rs_table_uuid(tbl: ExternalPtr<RTable>) -> String {
    tbl.metadata().uuid().to_string()
}

/// The schema, as parallel columns ready to become a tibble.
///
/// `snapshot_id` selects the schema in force at that snapshot rather than the
/// current one, which is what a time-travelling read has to resolve its column
/// names against.
#[extendr]
fn rs_table_schema(tbl: ExternalPtr<RTable>, snapshot_id: Nullable<String>) -> RResult<List> {
    let snapshot = tbl.resolve_snapshot_opt(&snapshot_id.into_option())?;
    let schema = tbl.schema_at(snapshot)?;
    let fields = schema.as_struct().fields();

    let ids: Vec<i32> = fields.iter().map(|f| f.id).collect();
    let names: Vec<String> = fields.iter().map(|f| f.name.clone()).collect();
    let types: Vec<String> = fields.iter().map(|f| f.field_type.to_string()).collect();
    let required: Vec<bool> = fields.iter().map(|f| f.required).collect();
    let docs: Vec<Rstr> = fields
        .iter()
        .map(|f| match &f.doc {
            Some(d) => Rstr::from(d.clone()),
            None => Rstr::na(),
        })
        .collect();

    // Named `field_type`, not `type`: `type` is a Rust keyword, so `list!` cannot
    // take it as an argument name. icebergr_schema() renames it back to `type`,
    // which is what the R-facing tibble has always been documented to have.
    Ok(list!(
        field_id = ids,
        name = names,
        field_type = types,
        required = required,
        doc = docs
    ))
}

/// The default partition spec.
#[extendr]
fn rs_table_partitions(tbl: ExternalPtr<RTable>) -> List {
    let metadata = tbl.metadata();
    let spec = metadata.default_partition_spec();
    let schema = metadata.current_schema();
    let fields = spec.fields();

    let spec_ids: Vec<i32> = fields.iter().map(|_| spec.spec_id()).collect();
    let field_ids: Vec<i32> = fields.iter().map(|f| f.field_id).collect();
    let source_ids: Vec<i32> = fields.iter().map(|f| f.source_id).collect();
    let source_names: Vec<Rstr> = fields
        .iter()
        .map(|f| match schema.field_by_id(f.source_id) {
            Some(src) => Rstr::from(src.name.clone()),
            None => Rstr::na(),
        })
        .collect();
    let names: Vec<String> = fields.iter().map(|f| f.name.clone()).collect();
    let transforms: Vec<String> = fields.iter().map(|f| f.transform.to_string()).collect();

    list!(
        spec_id = spec_ids,
        field_id = field_ids,
        name = names,
        transform = transforms,
        source_id = source_ids,
        source_name = source_names
    )
}

/// Snapshot history, oldest first.
#[extendr]
fn rs_table_snapshots(tbl: ExternalPtr<RTable>) -> List {
    let metadata = tbl.metadata();
    let mut snapshots: Vec<_> = metadata.snapshots().collect();
    // metadata.snapshots() iterates a hash map, so the input order is arbitrary.
    // Timestamps are only millisecond-resolution and two commits can land in the
    // same millisecond, so the sequence number breaks the tie: without it the
    // reported history -- and the snapshot that `as_of` resolves to -- would vary
    // between calls.
    snapshots.sort_by_key(|s| (s.timestamp_ms(), s.sequence_number()));

    let ids: Vec<String> = snapshots
        .iter()
        .map(|s| s.snapshot_id().to_string())
        .collect();
    let parents: Vec<Rstr> = snapshots
        .iter()
        .map(|s| match s.parent_snapshot_id() {
            Some(p) => Rstr::from(p.to_string()),
            None => Rstr::na(),
        })
        .collect();
    let seqs: Vec<f64> = snapshots
        .iter()
        .map(|s| s.sequence_number() as f64)
        .collect();
    let ts: Vec<f64> = snapshots.iter().map(|s| s.timestamp_ms() as f64).collect();
    let ops: Vec<String> = snapshots
        .iter()
        .map(|s| s.summary().operation.as_str().to_string())
        .collect();
    let manifests: Vec<String> = snapshots
        .iter()
        .map(|s| s.manifest_list().to_string())
        .collect();
    let schema_ids: Vec<Rint> = snapshots
        .iter()
        .map(|s| match s.schema_id() {
            Some(id) => Rint::from(id),
            None => Rint::na(),
        })
        .collect();
    // The free-form part of the summary carries row and file counts, which are
    // what makes a snapshot listing actually useful. Handed over as JSON so no
    // information is dropped on the way.
    let summaries: Vec<String> = snapshots
        .iter()
        .map(|s| {
            serde_json::to_string(&s.summary().additional_properties)
                .unwrap_or_else(|_| "{}".to_string())
        })
        .collect();

    list!(
        snapshot_id = ids,
        parent_snapshot_id = parents,
        sequence_number = seqs,
        timestamp_ms = ts,
        operation = ops,
        schema_id = schema_ids,
        summary = summaries,
        manifest_list = manifests
    )
}

/// The snapshot log: which snapshot was the table's current one, and when.
///
/// Not the same thing as the snapshot *list*. `snapshots()` holds every snapshot
/// the metadata still carries, which after a rollback includes the ones it
/// abandoned, and on a branched table includes ones that were never on the main
/// line. The log is the record of what the table actually looked like over time,
/// so it is what a read "as of" a timestamp has to follow: a rollback appends a
/// log entry pointing back at an *earlier* snapshot, while the snapshot it
/// abandoned keeps its own later timestamp in the list.
///
/// Returned in log order rather than sorted. Iceberg only requires the log to be
/// chronological within a clock-skew tolerance, and where the two disagree it is
/// the commit order that says which snapshot superseded which.
#[extendr]
fn rs_table_history(tbl: ExternalPtr<RTable>) -> List {
    let log = tbl.metadata().history();
    let ids: Vec<String> = log.iter().map(|e| e.snapshot_id.to_string()).collect();
    let ts: Vec<f64> = log.iter().map(|e| e.timestamp_ms() as f64).collect();
    list!(snapshot_id = ids, timestamp_ms = ts)
}

#[extendr]
fn rs_table_current_snapshot(tbl: ExternalPtr<RTable>) -> Nullable<String> {
    match tbl.metadata().current_snapshot_id() {
        Some(id) => NotNull(id.to_string()),
        None => Null,
    }
}

#[extendr]
fn rs_table_properties(tbl: ExternalPtr<RTable>) -> List {
    let props: &HashMap<String, String> = tbl.metadata().properties();
    let mut keys: Vec<&String> = props.keys().collect();
    keys.sort();
    let names: Vec<String> = keys.iter().map(|k| (*k).clone()).collect();
    let values: Vec<String> = keys.iter().map(|k| props[*k].clone()).collect();
    list!(name = names, value = values)
}

extendr_module! {
    mod table;
    fn rs_table_open;
    fn rs_table_exists;
    fn rs_table_reload;
    fn rs_create_table;
    fn rs_register_table;
    fn rs_table_identifier;
    fn rs_table_location;
    fn rs_table_format_version;
    fn rs_table_uuid;
    fn rs_table_schema;
    fn rs_table_partitions;
    fn rs_table_snapshots;
    fn rs_table_history;
    fn rs_table_current_snapshot;
    fn rs_table_properties;
}
