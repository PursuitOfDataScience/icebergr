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
// vec_init_then_push fires only when *every* feature is enabled, which is the one
// build where the pushes are not cfg'd away. The `vec![]` it suggests cannot be
// written here: each element exists or not depending on a cfg.
#[allow(clippy::vec_init_then_push)]
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

/// Whether an external pointer still points at anything.
///
/// A catalog or table handle that has been through `saveRDS()`/`readRDS()`,
/// restored from a `.RData` file, or sent to a serialising parallel worker comes
/// back as a *null* external pointer: R serialises the box, never the Rust value
/// behind it. extendr does catch the dereference, but it reports the mechanism
/// ("expected non-null pointer in externalptr") rather than the mistake, which
/// reads like a bug in the package. R checks with this first and explains.
#[extendr]
fn rs_ptr_is_null(x: Robj) -> bool {
    if x.rtype() != Rtype::ExternalPtr {
        return true;
    }
    // SAFETY: guarded above on the SEXP really being an EXTPTRSXP. Reading the
    // address neither dereferences it nor takes ownership of anything.
    unsafe { x.external_ptr_addr::<std::ffi::c_void>().is_null() }
}

extendr_module! {
    mod icebergr;
    fn rs_build_info;
    fn rs_ptr_is_null;
    use panic;
    use catalog;
    use table;
    use scan;
    use write;
}
