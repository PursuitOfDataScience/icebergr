//! R bindings to Apache Iceberg Rust.
//!
//! The Rust side is deliberately thin: it owns the tokio runtime, holds catalog
//! and table handles, and moves Arrow batches across the boundary. Everything
//! that can be expressed in R -- argument checking, filter translation, tibble
//! construction -- lives in R, where it is easier to test and to read.

mod arrow_bridge;
mod catalog;
mod errors;
mod panic;
mod predicate;
mod runtime;
mod scan;
mod table;
mod write;

use extendr_api::prelude::*;

/// Which optional Cargo features this binary was compiled with.
fn enabled_features() -> Vec<String> {
    // Every push below is cfg-gated, so in a default build none of them survive
    // and the binding is never actually mutated.
    #[allow(unused_mut)]
    let mut features: Vec<String> = Vec::new();
    #[cfg(feature = "s3")]
    features.push("s3".to_string());
    #[cfg(feature = "glue")]
    features.push("glue".to_string());
    features
}

/// Facts about this specific build.
///
/// Reported by `icebergr_spec_support()` so that "is Glue available?" is a
/// question R can answer without trying it and reading the error.
#[extendr]
fn rs_build_info() -> List {
    list!(
        iceberg_rust_version = "0.10.0",
        arrow_version = "58.4",
        features = enabled_features(),
        catalogs = {
            // As above: the only push is cfg-gated behind the glue feature.
            #[allow(unused_mut)]
            let mut c = vec!["rest".to_string(), "memory".to_string()];
            #[cfg(feature = "glue")]
            c.push("glue".to_string());
            c
        },
        object_storage = cfg!(feature = "s3")
    )
}

extendr_module! {
    mod icebergr;
    fn rs_build_info;
    use panic;
    use catalog;
    use table;
    use scan;
    use write;
}
