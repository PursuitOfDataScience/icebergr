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
//!
//! There is a second quiet case, and it is ours rather than extendr's.
//! `runtime::block_on` gives up by panicking when the user interrupts or the
//! timeout elapses, because `F::Output` is the future's own type and there is no
//! error value to put in it. Those are deliberate aborts carrying a message
//! written for a user, and without this they print the same banner: someone who
//! pressed Ctrl-C gets `panicked at src/runtime.rs:168` and a backtrace hint,
//! which reads like a crash rather than an answer. Verified by running it.
//!
//! They are recognised by payload rather than by location. Every one starts
//! `icebergr: `, which is a statement of intent; the file they are raised from
//! is not, and keying on it would silence a genuine bug that happened to panic
//! in the same module.

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

/// The prefix every deliberate abort in this crate carries.
const DELIBERATE: &str = "icebergr: ";

/// Whether this panic is one of ours, raised on purpose to end a call.
///
/// `block_on` uses one for an interrupt and one for the timeout, and the
/// runtime's `expect` carries the same prefix. All three already say what
/// happened in terms a user can act on, and extendr re-raises the payload as the
/// R error, so the banner adds nothing but alarm.
fn is_deliberate_abort(info: &PanicHookInfo<'_>) -> bool {
    let payload = info.payload();
    // A panic payload is `&str` for `panic!("literal")` and `expect("...")`,
    // and `String` once a format argument is involved.
    let message = payload
        .downcast_ref::<&str>()
        .copied()
        .or_else(|| payload.downcast_ref::<String>().map(String::as_str));
    is_deliberate_message(message)
}

/// The decision itself, separated from getting at the payload.
///
/// Split out so it can be tested directly. Testing it through a real panic
/// means swapping the process-wide hook, and two tests doing that in parallel
/// race: one restores a hook the other installed, a panic then fires inside a
/// hook, and the process aborts with "panicked while processing panic". That
/// version of this test passed once and aborted the next run.
pub(crate) fn is_deliberate_message(message: Option<&str>) -> bool {
    message.is_some_and(|m| m.starts_with(DELIBERATE))
}

/// Install the hook. Idempotent, and safe to call before anything else.
pub fn install() {
    INSTALLED.call_once(|| {
        let previous = take_hook();
        set_hook(Box::new(move |info| {
            let quiet = is_error_conversion(info) || is_deliberate_abort(info);
            if wants_full_report() || !quiet {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn our_own_aborts_are_recognised() {
        for m in [
            "icebergr: interrupted.",
            "icebergr: gave up after 300s waiting for the catalog or storage to respond.",
            "icebergr: could not start the tokio runtime",
        ] {
            assert!(is_deliberate_message(Some(m)), "{m}");
        }
    }

    #[test]
    fn a_genuine_bug_is_not_recognised() {
        // A silenced panic is a silenced bug, so these must keep printing.
        for m in [
            "index out of bounds: the len is 3 but the index is 7",
            "called `Option::unwrap()` on a `None` value",
            "attempt to divide by zero",
            // The prefix has to start the message, not merely appear in it.
            "something went wrong in icebergr: really",
            // And a near miss on the prefix is not a match.
            "icebergr:no space after the colon",
        ] {
            assert!(!is_deliberate_message(Some(m)), "{m}");
        }
    }

    #[test]
    fn a_payload_that_is_neither_str_nor_string_is_not_ours() {
        // `panic_any(42)` yields a payload this cannot read; it must not be
        // mistaken for a deliberate abort and silenced.
        assert!(!is_deliberate_message(None));
    }
}
