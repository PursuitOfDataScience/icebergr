//! Catalog connections.
//!
//! Three catalog kinds are reachable from R: `rest`, `memory` and `glue`.
//! `memory` is an in-process catalog over a warehouse directory, which is what
//! makes fully offline use -- and the entire test suite -- possible.
//!
//! Note that iceberg-rust has no Hadoop or filesystem catalog, so there is
//! deliberately no `hadoop` option here; `memory` is the local-warehouse
//! equivalent.
//!
//! Catalog properties are passed straight through as an opaque map. Their values
//! frequently are credentials, so no code path here formats them into a
//! message, a log line or a print method.

use std::collections::HashMap;
use std::sync::Arc;

use extendr_api::prelude::*;
use iceberg::io::{LocalFsStorageFactory, StorageFactory};
use iceberg::memory::MemoryCatalogBuilder;
use iceberg::{Catalog, CatalogBuilder, NamespaceIdent};
use iceberg_catalog_rest::RestCatalogBuilder;

// not_compiled_in is referenced by full path below: whether it is used at all
// depends on which optional features are enabled, and an import that is unused
// under some feature combinations is a warning we would rather not have.
use crate::errors::{RResult, config_err, ctx};
use crate::runtime::{block_on, iceberg_runtime};

/// A live catalog connection, handed to R as an external pointer.
///
/// Only the catalog itself. The kind and the connection name live on the R-side
/// `icebergr_catalog` object, which is the one place they are read from; keeping
/// a second copy here that nothing reads is state that can only drift.
pub struct RCatalog {
    pub inner: Arc<dyn Catalog>,
}

/// Whether `w` starts with `scheme://`, ignoring case.
///
/// A URI scheme is case-insensitive, and iceberg-rust's `FileIO` treats it so,
/// since it parses locations as URLs: `S3://bucket` is an S3 location to it. The
/// R side already matched `s3://` case-insensitively when deciding whether to
/// forward AWS credentials, so a case-sensitive test here disagreed with it and
/// put an `S3://` warehouse on the local filesystem.
fn has_scheme(w: &str, scheme: &str) -> bool {
    w.len() > scheme.len() + 3
        && w.as_bytes()[..scheme.len()].eq_ignore_ascii_case(scheme.as_bytes())
        && w.as_bytes()[scheme.len()..].starts_with(b"://")
}

fn looks_like_local_path(w: &str) -> bool {
    let b = w.as_bytes();
    has_scheme(w, "file")
        || w.starts_with('/')
        // Windows drive letter, e.g. C:\warehouse. The leading byte has to be a
        // letter: without that check any string with a colon in second position
        // is read as a local path.
        || (b.len() > 2
            && b[0].is_ascii_alphabetic()
            && b[1] == b':'
            && (b[2] == b'\\' || b[2] == b'/'))
}

#[cfg(feature = "s3")]
fn s3_factory() -> RResult<Arc<dyn StorageFactory>> {
    Ok(Arc::new(
        iceberg_storage_opendal::OpenDalStorageFactory::S3 {
            customized_credential_load: None,
        },
    ))
}

#[cfg(not(feature = "s3"))]
fn s3_factory() -> RResult<Arc<dyn StorageFactory>> {
    Err(crate::errors::not_compiled_in(
        "Object storage (S3) access",
        "s3",
    ))
}

/// Choose the storage backend.
///
/// `None` means "leave the builder's own default alone", which is the right
/// answer for a REST catalog that reports its own storage configuration.
fn storage_factory(
    storage: &str,
    warehouse: Option<&str>,
) -> RResult<Option<Arc<dyn StorageFactory>>> {
    match resolve_storage(storage, warehouse) {
        "local" => Ok(Some(
            Arc::new(LocalFsStorageFactory) as Arc<dyn StorageFactory>
        )),
        "s3" => s3_factory().map(Some),
        "default" => Ok(None),
        other => Err(extendr_api::Error::Other(format!(
            "unknown storage backend {other:?}; expected \"auto\", \"local\" or \"s3\""
        ))),
    }
}

/// Which backend `storage` names, reading `"auto"` off the warehouse.
fn resolve_storage<'a>(storage: &'a str, warehouse: Option<&str>) -> &'a str {
    if storage != "auto" {
        return storage;
    }
    match warehouse {
        Some(w) if has_scheme(w, "s3") || has_scheme(w, "s3a") => "s3",
        Some(w) if looks_like_local_path(w) => "local",
        _ => "default",
    }
}

#[cfg(feature = "glue")]
fn connect_glue(
    name: &str,
    props: HashMap<String, String>,
    factory: Option<Arc<dyn StorageFactory>>,
    keys: &[String],
) -> RResult<Arc<dyn Catalog>> {
    let mut builder =
        iceberg_catalog_glue::GlueCatalogBuilder::default().with_runtime(iceberg_runtime());
    // Glue tables live in object storage, so default to S3 rather than to the
    // local filesystem.
    let factory = match factory {
        Some(f) => f,
        None => s3_factory()?,
    };
    builder = builder.with_storage_factory(factory);

    let catalog = block_on(builder.load(name.to_string(), props))
        .map_err(|e| config_err("could not connect to the AWS Glue catalog", keys, e))?;
    Ok(Arc::new(catalog))
}

#[cfg(not(feature = "glue"))]
fn connect_glue(
    _name: &str,
    _props: HashMap<String, String>,
    _factory: Option<Arc<dyn StorageFactory>>,
    _keys: &[String],
) -> RResult<Arc<dyn Catalog>> {
    Err(crate::errors::not_compiled_in(
        "The AWS Glue catalog",
        "glue",
    ))
}

#[extendr]
fn rs_catalog_connect(
    kind: &str,
    name: &str,
    storage: &str,
    keys: Vec<String>,
    values: Vec<String>,
) -> RResult<ExternalPtr<RCatalog>> {
    if keys.len() != values.len() {
        return Err("internal error: property keys and values differ in length".into());
    }

    let props: HashMap<String, String> = keys.iter().cloned().zip(values).collect();
    let warehouse = props.get("warehouse").cloned();
    let factory = storage_factory(storage, warehouse.as_deref())?;

    let inner: Arc<dyn Catalog> = match kind {
        "memory" => {
            // MemoryCatalog defaults to *in-memory* storage, which would write a
            // local warehouse into oblivion, so a factory is always set.
            let factory = factory.unwrap_or_else(|| Arc::new(LocalFsStorageFactory));
            let builder = MemoryCatalogBuilder::default()
                .with_runtime(iceberg_runtime())
                .with_storage_factory(factory);
            let catalog = block_on(builder.load(name.to_string(), props))
                .map_err(|e| config_err("could not open the memory catalog", &keys, e))?;
            Arc::new(catalog)
        }
        "rest" => {
            let mut builder = RestCatalogBuilder::default().with_runtime(iceberg_runtime());
            if let Some(f) = factory {
                builder = builder.with_storage_factory(f);
            }
            let catalog = block_on(builder.load(name.to_string(), props))
                .map_err(|e| config_err("could not connect to the REST catalog", &keys, e))?;
            Arc::new(catalog)
        }
        "glue" => connect_glue(name, props, factory, &keys)?,
        other => {
            return Err(extendr_api::Error::Other(format!(
                "unknown catalog type {other:?}.\n\
                 icebergr supports \"rest\", \"memory\" and \"glue\". Note that \
                 iceberg-rust has no Hadoop or filesystem catalog; use \
                 type = \"memory\" with a warehouse directory for a local table."
            )));
        }
    };

    Ok(ExternalPtr::new(RCatalog { inner }))
}

/// Namespaces are multi-level; each is returned as a dot-joined string.
#[extendr]
fn rs_list_namespaces(cat: ExternalPtr<RCatalog>, parent: Vec<String>) -> RResult<Vec<String>> {
    let parent = if parent.is_empty() {
        None
    } else {
        Some(NamespaceIdent::from_vec(parent).map_err(|e| ctx("invalid namespace", e))?)
    };

    let found = block_on(cat.inner.list_namespaces(parent.as_ref()))
        .map_err(|e| ctx("could not list namespaces", e))?;

    Ok(found.iter().map(|n| n.as_ref().join(".")).collect())
}

/// Table names within `namespace`, without the namespace prefix.
#[extendr]
fn rs_list_tables(cat: ExternalPtr<RCatalog>, namespace: Vec<String>) -> RResult<Vec<String>> {
    let ns = NamespaceIdent::from_vec(namespace).map_err(|e| ctx("invalid namespace", e))?;
    let found =
        block_on(cat.inner.list_tables(&ns)).map_err(|e| ctx("could not list tables", e))?;
    Ok(found.iter().map(|t| t.name().to_string()).collect())
}

#[extendr]
fn rs_namespace_exists(cat: ExternalPtr<RCatalog>, namespace: Vec<String>) -> RResult<bool> {
    let ns = NamespaceIdent::from_vec(namespace).map_err(|e| ctx("invalid namespace", e))?;
    block_on(cat.inner.namespace_exists(&ns)).map_err(|e| ctx("could not check namespace", e))
}

#[extendr]
fn rs_create_namespace(cat: ExternalPtr<RCatalog>, namespace: Vec<String>) -> RResult<()> {
    let ns = NamespaceIdent::from_vec(namespace).map_err(|e| ctx("invalid namespace", e))?;
    block_on(cat.inner.create_namespace(&ns, HashMap::new()))
        .map_err(|e| ctx("could not create namespace", e))?;
    Ok(())
}

extendr_module! {
    mod catalog;
    fn rs_catalog_connect;
    fn rs_list_namespaces;
    fn rs_list_tables;
    fn rs_namespace_exists;
    fn rs_create_namespace;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_scheme_matches_in_any_case_and_only_as_a_scheme() {
        assert!(has_scheme("s3://bucket/wh", "s3"));
        assert!(has_scheme("S3://bucket/wh", "s3"));
        assert!(has_scheme("File:///data/wh", "file"));
        // A prefix of the scheme, or the scheme with nothing after it, is not.
        assert!(!has_scheme("s3a://bucket/wh", "s3"));
        assert!(!has_scheme("s3://", "s3"));
        assert!(!has_scheme("s3", "s3"));
        assert!(!has_scheme("", "s3"));
    }

    #[test]
    fn auto_reads_the_backend_off_the_warehouse() {
        // The case that disagreed with the R side: an upper-case scheme was not
        // object storage here, so a memory catalog put it on the local disk.
        assert_eq!(resolve_storage("auto", Some("S3://bucket/wh")), "s3");
        assert_eq!(resolve_storage("auto", Some("s3a://bucket/wh")), "s3");
        assert_eq!(resolve_storage("auto", Some("/data/wh")), "local");
        assert_eq!(resolve_storage("auto", Some("C:/data/wh")), "local");
        assert_eq!(resolve_storage("auto", Some("FILE:///data/wh")), "local");
        // A REST warehouse identified by name leaves the builder's default.
        assert_eq!(resolve_storage("auto", Some("analytics")), "default");
        assert_eq!(resolve_storage("auto", None), "default");
        // An explicit choice is never second-guessed.
        assert_eq!(resolve_storage("local", Some("s3://bucket/wh")), "local");
    }
}
