//! A single shared tokio runtime for the lifetime of the R session.
//!
//! iceberg-rust is async throughout, while R is emphatically not. Every
//! entry point therefore drives a future to completion with `block_on` on
//! whichever thread R called us from. That thread is R's own, so it must never
//! be a runtime worker thread -- `block_on` panics if called from inside a
//! runtime -- which is why the runtime is separate from the calling thread and
//! we never re-enter.

use std::future::Future;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use tokio::runtime::{Builder, Runtime as TokioRuntime};

/// The runtime, and the id of the process that started it.
///
/// The id is what makes a fork detectable. A `fork()` copies the `OnceLock`
/// already initialised, but not the runtime's worker threads, which only ever
/// exist in the process that spawned them, so in a forked child nothing drives
/// the timer or the IO reactor and every `block_on` waits forever. Not even
/// Ctrl-C or the timeout can end it, since both are checked when a timed slice
/// elapses, and that needs the timer. `parallel::mclapply()` forks, so any
/// icebergr call made in the parent turned each worker's first call into a hang
/// with no error at all.
///
/// Rebuilding the runtime in the child would not rescue it: every catalog
/// handle keeps the parent's runtime, and its HTTP connection pool shares
/// sockets with the parent. So a child refuses, clearly, instead.
static TOKIO: OnceLock<(u32, TokioRuntime)> = OnceLock::new();

/// The largest number of worker threads `ICEBERGR_WORKER_THREADS` may ask for.
///
/// Each thread costs a stack, and the work here is IO bound, so a large value
/// buys nothing. Unbounded, a typo (or an env var holding a byte count) spawns
/// threads until the allocator gives up, which takes R down with it. Clamped
/// rather than rejected: the intent of a big number is "as parallel as you can",
/// and that is what it gets.
const MAX_WORKER_THREADS: usize = 64;

/// Default wall-clock ceiling on a single await, in seconds.
const DEFAULT_TIMEOUT_SECONDS: u64 = 300;

/// The shared runtime, started on first use.
///
/// Two worker threads by default. That keeps us inside CRAN's limit on
/// parallelism during checks and is ample for work that is almost entirely IO
/// bound; it can be raised for large scans with `ICEBERGR_WORKER_THREADS`, up
/// to `MAX_WORKER_THREADS`.
fn tokio_runtime() -> &'static TokioRuntime {
    let (owner, rt) = TOKIO.get_or_init(|| {
        let workers = std::env::var("ICEBERGR_WORKER_THREADS")
            .ok()
            .and_then(|v| v.parse::<usize>().ok())
            .filter(|n| *n > 0)
            .map(|n| n.min(MAX_WORKER_THREADS))
            .unwrap_or(2);

        let rt = Builder::new_multi_thread()
            .worker_threads(workers)
            .thread_name("icebergr")
            .enable_all()
            .build()
            .expect("icebergr: could not start the tokio runtime");
        (std::process::id(), rt)
    });
    if !owned_by_this_process(*owner) {
        // A panic, like the interrupt and the timeout, because callers want the
        // runtime itself rather than a Result; see block_on for why that is
        // safe. The prefix keeps the panic hook quiet.
        panic!(
            "icebergr: this process was forked from one that had already used \
             icebergr, and its async runtime does not survive a fork, so nothing \
             here can complete. Use a PSOCK cluster, from parallel::makeCluster(), \
             rather than parallel::mclapply(), and open the catalog inside each \
             worker."
        );
    }
    rt
}

/// Whether the runtime recorded as started by `owner` belongs to this process.
fn owned_by_this_process(owner: u32) -> bool {
    owner == std::process::id()
}

/// How long a single await may take before it is abandoned.
///
/// `ICEBERGR_TIMEOUT_SECONDS` overrides it; `0` disables the ceiling entirely.
fn timeout_duration() -> Option<Duration> {
    let secs = std::env::var("ICEBERGR_TIMEOUT_SECONDS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(DEFAULT_TIMEOUT_SECONDS);
    (secs > 0).then(|| Duration::from_secs(secs))
}

/// How often to come back to R's thread and look at its interrupt flag.
///
/// Five times a second: responsive enough that Ctrl-C feels immediate, rare
/// enough to cost nothing against work measured in network round trips.
const POLL: Duration = Duration::from_millis(200);

// R's interrupt flag. R's SIGINT handler sets it, and R clears it when it
// raises the condition at its next check point -- which never comes while
// `block_on` is parked on R's own thread.
//
// Declared here because `extendr` 0.9 has no interrupt API at all: not a
// wrapper, not a binding, no mention of interrupts anywhere in its source. The
// name differs by platform, and both are exported for packages to read.
//
// Reading the flag is the safe half of R's interrupt story. The unsafe half is
// `R_CheckUserInterrupt()`, which longjmps -- straight past the pinned future
// and the open Arrow stream below, running no destructor on the way. So this
// only reads and clears, and turns the answer into an ordinary error.
#[cfg(not(target_os = "windows"))]
unsafe extern "C" {
    static mut R_interrupts_pending: std::ffi::c_int;
}
#[cfg(target_os = "windows")]
unsafe extern "C" {
    static mut UserBreak: std::ffi::c_int;
}

/// The address of whichever flag this platform calls it.
fn interrupt_flag() -> *mut std::ffi::c_int {
    #[cfg(not(target_os = "windows"))]
    {
        &raw mut R_interrupts_pending
    }
    #[cfg(target_os = "windows")]
    {
        &raw mut UserBreak
    }
}

/// Has the user pressed Ctrl-C? Clears the flag if so.
///
/// Cleared because we are about to report the interrupt ourselves, as an error
/// from this call. Leaving it set would have R raise it a second time at its
/// next check point, against whatever the caller did next.
fn take_interrupt() -> bool {
    // SAFETY: a single `int` owned by R, read and written only from R's own
    // thread -- which is this one, since `block_on` runs where R called us and
    // the loop below only looks at the flag between `rt.block_on` slices, never
    // from a runtime worker.
    unsafe {
        let flag = interrupt_flag();
        if *flag != 0 {
            *flag = 0;
            true
        } else {
            false
        }
    }
}

/// Run `fut` to completion on the shared runtime, interruptibly and under a
/// timeout.
///
/// `block_on` parks R's own thread, and R only tests its interrupt flag between
/// evaluations, so a naive one makes Ctrl-C do nothing at all: a slow catalog,
/// a large scan or an object store that has stopped answering each leave the
/// session unresponsive until it finishes. So the future is polled in `POLL`
/// slices, and between slices -- back on R's thread, outside the runtime --
/// this looks at R's flag.
///
/// The timeout is the backstop for the case Ctrl-C cannot reach, such as a
/// non-interactive session. Each call is one unit of work -- a metadata
/// request, or a single record batch -- so it bounds one await rather than a
/// whole read, and a large scan is many awaits and is not truncated by it.
///
/// Both give up by panicking rather than returning, because `F::Output` is the
/// future's own type and there is no error value to put in it. That is the
/// mechanism extendr documents: it wraps every `#[extendr]` call in
/// `catch_unwind` and turns a panic into an R condition, which is also why
/// `panic = "unwind"` is pinned in Cargo.toml. The one path with no extendr
/// frame on the stack, pulling batches 2..n, has its own `catch_unwind` in
/// `arrow_bridge`.
pub fn block_on<F: Future>(fut: F) -> F::Output {
    let rt = tokio_runtime();
    let deadline = timeout_duration().map(|d| (Instant::now() + d, d));

    // Pinned once, outside the loop, so each slice resumes the same future
    // rather than restarting it. `tokio::time::timeout` on a `&mut` borrow
    // leaves the future untouched when the slice elapses.
    let mut fut = Box::pin(fut);
    loop {
        // Constructed inside the async block, not passed in already built:
        // `tokio::time::timeout` registers its `Sleep` with the current timer
        // when it is created, and creating it on R's thread -- outside any
        // runtime -- fails with "there is no reactor running, must be called
        // from the context of a Tokio 1.x runtime", which turned every catalog
        // call into an error.
        let slice = rt.block_on(async { tokio::time::timeout(POLL, &mut fut).await });
        if let Ok(out) = slice {
            return out;
        }

        if take_interrupt() {
            panic!("icebergr: interrupted.");
        }

        if let Some((at, total)) = deadline
            && Instant::now() >= at
        {
            panic!(
                "icebergr: gave up after {}s waiting for the catalog or storage \
                 to respond. Raise or remove the ceiling with \
                 ICEBERGR_TIMEOUT_SECONDS (0 disables it).",
                total.as_secs()
            );
        }
    }
}

/// The iceberg-rust runtime handle wrapping our runtime.
///
/// Passed explicitly to every catalog builder. `Runtime::current()` would
/// otherwise be called inside `load()`, which only works when already inside a
/// runtime context and would tie the catalog to whatever happened to be current.
pub fn iceberg_runtime() -> iceberg::Runtime {
    iceberg::Runtime::new(tokio_runtime())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Serialises every test in this module.
    ///
    /// They all touch process-global state -- R's interrupt flag, and
    /// `ICEBERGR_TIMEOUT_SECONDS` -- and `cargo test` runs tests in parallel,
    /// so without this they collide in three ways that all look like flakes:
    /// `raise()` setting the flag while another test is mid-`block_on`, which
    /// reads it between slices and would abort that test as "interrupted"; the
    /// timeout test's 1-second ceiling being inherited by every other
    /// `block_on`; and two tests disagreeing about whether the flag starts set.
    ///
    /// An earlier version of this module asserted the suite was
    /// single-threaded. It is not, and that claim was doing the work a lock
    /// should.
    static TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    /// Run `f` with the module's globals to itself, leaving the flag clear.
    fn serialised<T>(f: impl FnOnce() -> T) -> T {
        // Poisoning is expected: one of these tests panics on purpose.
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        clear();
        let out = f();
        clear();
        out
    }

    /// Set the flag the way R's SIGINT handler would.
    fn raise() {
        // SAFETY: a single `int` owned by R, and `serialised` holds the lock.
        unsafe { *interrupt_flag() = 1 };
    }

    fn clear() {
        // SAFETY: as above.
        unsafe { *interrupt_flag() = 0 };
    }

    #[test]
    fn a_runtime_started_by_another_process_is_not_ours() {
        // What a forked child sees: the id recorded when the runtime started is
        // its parent's. Refusing there is what stands between mclapply() and a
        // hang with no error, so the comparison is pinned both ways.
        assert!(owned_by_this_process(std::process::id()));
        assert!(!owned_by_this_process(std::process::id().wrapping_add(1)));
    }

    #[test]
    fn take_interrupt_is_false_when_nothing_is_pending() {
        serialised(|| assert!(!take_interrupt()));
    }

    #[test]
    fn take_interrupt_sees_a_raised_flag_and_clears_it() {
        serialised(|| {
            raise();
            assert!(take_interrupt(), "a raised flag must be seen");
            assert!(
                !take_interrupt(),
                "and cleared, so R does not raise it a second time against \
                 whatever the caller does next"
            );
        });
    }

    #[test]
    fn a_future_that_finishes_inside_one_slice_returns_normally() {
        serialised(|| assert_eq!(block_on(async { 41 + 1 }), 42));
    }

    #[test]
    fn a_future_spanning_several_slices_still_returns_its_value() {
        // POLL is 200ms, so this one is resumed rather than restarted -- the
        // bug a future pinned inside the loop instead of outside it would have.
        serialised(|| {
            let out = block_on(async {
                tokio::time::sleep(Duration::from_millis(450)).await;
                "resumed"
            });
            assert_eq!(out, "resumed");
        });
    }

    #[test]
    fn an_interrupt_raised_mid_flight_ends_the_call() {
        // The behaviour the poll loop exists for, without needing a signal:
        // the flag is raised from a thread while block_on is parked.
        serialised(|| {
            std::thread::spawn(|| {
                std::thread::sleep(Duration::from_millis(300));
                raise();
            });
            let caught = std::panic::catch_unwind(|| {
                block_on(async { tokio::time::sleep(Duration::from_secs(30)).await })
            });
            let err = caught.expect_err("a raised flag must end the call");
            let msg = err
                .downcast_ref::<&str>()
                .copied()
                .or_else(|| err.downcast_ref::<String>().map(String::as_str))
                .unwrap_or_default();
            assert!(msg.contains("interrupted"), "{msg}");
        });
    }

    #[test]
    fn the_timeout_still_fires_when_nothing_completes() {
        serialised(|| {
            temp_env_var("ICEBERGR_TIMEOUT_SECONDS", "1", || {
                let caught = std::panic::catch_unwind(|| {
                    block_on(async { tokio::time::sleep(Duration::from_secs(30)).await })
                });
                let err = caught.expect_err("a 30s sleep under a 1s ceiling must give up");
                let msg = err
                    .downcast_ref::<String>()
                    .map(String::as_str)
                    .unwrap_or_default();
                assert!(msg.contains("gave up after 1s"), "{msg}");
            });
        });
    }

    /// `std::env::set_var` is unsafe in edition 2024 because another thread may
    /// be reading the environment. Callers hold `TEST_LOCK`, which keeps the
    /// other tests in this module out; nothing else in the crate reads this
    /// variable except `timeout_duration`, from these same tests.
    fn temp_env_var(key: &str, value: &str, f: impl FnOnce()) {
        let old = std::env::var(key).ok();
        // SAFETY: see above.
        unsafe { std::env::set_var(key, value) };
        f();
        match old {
            // SAFETY: as above.
            Some(v) => unsafe { std::env::set_var(key, v) },
            None => unsafe { std::env::remove_var(key) },
        }
    }
}
