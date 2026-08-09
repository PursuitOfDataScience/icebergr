//! Keeping ordinary R errors from printing a Rust panic banner.
//!
//! extendr turns an `Err` returned by an `#[extendr]` function into a panic,
//! catches it, and re-raises it as an R error carrying the same message. That is
//! the right design -- a `longjmp` through Rust frames would be undefined
//! behaviour -- but it means the process-wide panic hook runs first, and the
//! default hook writes
//!
//! ```text
//! thread '<unnamed>' panicked at .../into_robj.rs:73:25:
//! could not open table db.absent: TableNotFound => ...
//! ```
//!
//! to file descriptor 2 for every routine mistake a user makes. R never sees
//! it, so it cannot be caught, suppressed or captured by knitr; it just appears
//! alongside the real error, looking like a crash. `R CMD check` logs collect it
//! too.
//!
//! So the hook is replaced with one that stays quiet for exactly that case and
//! defers to the previous hook for everything else, which keeps a genuine bug --
//! an unwrap on `None`, an out-of-bounds index -- as visible as it was.

use std::panic::{PanicHookInfo, set_hook, take_hook};
use std::sync::Once;

use extendr_api::prelude::*;

static INSTALLED: Once = Once::new();

/// Full panic reporting, for when the terse form is not enough.
fn wants_full_report() -> bool {
    std::env::var_os("RUST_BACKTRACE").is_some()
        || std::env::var_os("ICEBERGR_RUST_PANIC_TRACE").is_some()
}

/// Whether this panic is extendr converting an `Err` into an R error.
///
/// Identified by source location rather than by payload: the payload is just
/// the error message, which is indistinguishable from any other panic's.
fn is_error_conversion(info: &PanicHookInfo<'_>) -> bool {
    match info.location() {
        Some(loc) => {
            let file = loc.file().replace('\\', "/");
            file.contains("extendr-api") && file.ends_with("/robj/into_robj.rs")
        }
        None => false,
    }
}

/// Install the hook. Idempotent, and safe to call before anything else.
pub fn install() {
    INSTALLED.call_once(|| {
        let previous = take_hook();
        set_hook(Box::new(move |info| {
            if wants_full_report() || !is_error_conversion(info) {
                previous(info);
            }
        }));
    });
}

/// Called from `.onLoad()`.
#[extendr]
fn rs_install_panic_hook() {
    install();
}

extendr_module! {
    mod panic;
    fn rs_install_panic_hook;
}
