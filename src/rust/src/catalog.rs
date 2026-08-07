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
pub struct RCatalog {
    pub inner: Arc<dyn Catalog>,
    pub kind: String,
    pub name: String,
}

fn looks_like_local_path(w: &str) -> bool {
    let b = w.as_bytes();
    w.starts_with("file://")
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
    let resolved = if storage == "auto" {
        match warehouse {
            Some(w) if w.starts_with("s3://") || w.starts_with("s3a://") => "s3",
            Some(w) if looks_like_local_path(w) => "local",
            _ => "default",
        }
    } else {
        storage
    };

    match resolved {
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

    let props: HashMap<String, String> = keys.iter().cloned().zip(values.into_iter()).collect();
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

    Ok(ExternalPtr::new(RCatalog {
        inner,
        kind: kind.to_string(),
        name: name.to_string(),
    }))
}

#[extendr]
fn rs_catalog_kind(cat: ExternalPtr<RCatalog>) -> String {
    cat.kind.clone()
}

#[extendr]
fn rs_catalog_name(cat: ExternalPtr<RCatalog>) -> String {
    cat.name.clone()
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
    fn rs_catalog_kind;
    fn rs_catalog_name;
    fn rs_list_namespaces;
    fn rs_list_tables;
    fn rs_namespace_exists;
    fn rs_create_namespace;
}
