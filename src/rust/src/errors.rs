//! Turning Rust errors into R conditions, without leaking secrets.
//!
//! Catalog configuration carries bearer tokens, secret access keys and
//! signing credentials. An error message that echoes the offending
//! configuration is an excellent way to write a token into a knitr cache, a CI
//! log, or an R history file, so nothing here ever formats a property *value*.
//! Only key names are reported.

use extendr_api::Error as RError;

pub type RResult<T> = std::result::Result<T, RError>;

/// Wrap an error with context, for cases where the error text is safe.
pub fn ctx<E: std::fmt::Display>(what: &str, e: E) -> RError {
    RError::Other(format!("{what}: {e}"))
}

/// Report a failure that involves catalog configuration.
///
/// Lists the property keys that were supplied so the user can see what the
/// catalog was given, and deliberately never their values.
pub fn config_err<E: std::fmt::Display>(what: &str, keys: &[String], e: E) -> RError {
    let listed = if keys.is_empty() {
        "none".to_string()
    } else {
        let mut sorted = keys.to_vec();
        sorted.sort();
        sorted.join(", ")
    };
    RError::Other(format!(
        "{what}: {e}\nProperties supplied (keys only, values withheld): {listed}"
    ))
}

/// An error for a feature that exists in Iceberg but is not compiled in.
pub fn not_compiled_in(what: &str, feature: &str) -> RError {
    RError::Other(format!(
        "{what} is not available in this build of icebergr.\n\
         It requires the optional Cargo feature \"{feature}\", which is off by \
         default because it substantially enlarges the dependency tree.\n\
         Reinstall from source with:\n  \
         ICEBERGR_CARGO_FEATURES={feature} R CMD INSTALL --preclean .\n\
         See vignette(\"catalog-configuration\", package = \"icebergr\")."
    ))
}

/// An error for a feature that iceberg-rust itself does not implement.
pub fn unsupported_upstream(what: &str) -> RError {
    RError::Other(format!(
        "{what} is not supported.\n\
         iceberg-rust 0.10.0, which icebergr is built on, does not implement \
         it. See icebergr_spec_support() for the full matrix of what is and is \
         not available."
    ))
}
