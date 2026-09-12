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
//! error value to put in it. Those are deliberate aborts with a message written
//! for a user, and before this they printed the same banner: someone who pressed
//! Ctrl-C got `panicked at src/runtime.rs:168` and a backtrace hint, which reads
//! like a crash rather than an answer.
//!
//! They are recognised by payload rather than by location. Every one of them
//! starts `icebergr: `, which is a statement of intent; the file they are raised
//! from is not, and keying on it would silence a genuine bug that happened to
//! panic in the same module.

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
    let message = payload
        .downcast_ref::<&str>()
        .copied()
        .or_else(|| payload.downcast_ref::<String>().map(String::as_str));
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

    /// Build a hook info for a payload, the only way to reach the predicate
    /// without actually panicking.
    fn deliberate(message: &str) -> bool {
        // `PanicHookInfo` cannot be constructed outside std, so the predicate is
        // exercised through a real panic and the hook it installs.
        let seen = std::sync::Arc::new(std::sync::Mutex::new(None::<bool>));
        let probe = std::sync::Arc::clone(&seen);
        let previous = take_hook();
        set_hook(Box::new(move |info| {
            *probe.lock().unwrap() = Some(is_deliberate_abort(info));
        }));
        let msg = message.to_string();
        let _ = std::panic::catch_unwind(move || panic!("{msg}"));
        set_hook(previous);
        seen.lock().unwrap().unwrap()
    }

    #[test]
    fn our_own_aborts_are_recognised() {
        assert!(deliberate("icebergr: interrupted."));
        assert!(deliberate(
            "icebergr: gave up after 300s waiting for the catalog or storage to respond."
        ));
        assert!(deliberate("icebergr: could not start the tokio runtime"));
    }

    #[test]
    fn a_genuine_bug_is_not_recognised() {
        // These must keep printing: a silenced panic is a silenced bug.
        assert!(!deliberate("index out of bounds: the len is 3 but the index is 7"));
        assert!(!deliberate("called `Option::unwrap()` on a `None` value"));
        assert!(!deliberate("attempt to divide by zero"));
        // And a message that merely mentions us is not a deliberate abort.
        assert!(!deliberate("something went wrong in icebergr: really"));
    }
}
