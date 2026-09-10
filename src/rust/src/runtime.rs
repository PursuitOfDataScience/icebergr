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
use std::time::Duration;

use tokio::runtime::{Builder, Runtime as TokioRuntime};

static TOKIO: OnceLock<TokioRuntime> = OnceLock::new();

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
    TOKIO.get_or_init(|| {
        let workers = std::env::var("ICEBERGR_WORKER_THREADS")
            .ok()
            .and_then(|v| v.parse::<usize>().ok())
            .filter(|n| *n > 0)
            .map(|n| n.min(MAX_WORKER_THREADS))
            .unwrap_or(2);

        Builder::new_multi_thread()
            .worker_threads(workers)
            .thread_name("icebergr")
            .enable_all()
            .build()
            .expect("icebergr: could not start the tokio runtime")
    })
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

/// Run `fut` to completion on the shared runtime, under a timeout.
///
/// Without one, a catalog that accepts the connection and then never answers
/// wedges the session permanently: `block_on` parks R's own thread, and R only
/// tests its interrupt flag between evaluations, so Ctrl-C does nothing. The
/// ceiling turns that into an ordinary R error.
///
/// Each call is one unit of work -- a metadata request, or a single record
/// batch -- so this bounds one await rather than a whole read. A large scan is
/// many awaits and is not truncated by it.
///
/// The elapsed case panics rather than returning, because `F::Output` is the
/// future's own type and there is no timeout value to put in it. That is the
/// mechanism extendr documents: it wraps every `#[extendr]` call in
/// `catch_unwind` and turns a panic into an R condition, which is also why
/// `panic = "unwind"` is pinned in Cargo.toml. The one path with no extendr
/// frame on the stack, pulling batches 2..n, has its own `catch_unwind` in
/// `arrow_bridge`.
pub fn block_on<F: Future>(fut: F) -> F::Output {
    let rt = tokio_runtime();
    match timeout_duration() {
        None => rt.block_on(fut),
        // The timeout is constructed *inside* the async block, not passed into
        // block_on already built. `tokio::time::timeout` registers its `Sleep`
        // with the current timer on creation, and creating it on R's thread --
        // outside any runtime -- fails with "there is no reactor running, must
        // be called from the context of a Tokio 1.x runtime", turning every
        // catalog call into an error.
        Some(d) => match rt.block_on(async move { tokio::time::timeout(d, fut).await }) {
            Ok(out) => out,
            Err(_) => panic!(
                "icebergr: gave up after {}s waiting for the catalog or storage \
                 to respond. Raise or remove the ceiling with \
                 ICEBERGR_TIMEOUT_SECONDS (0 disables it).",
                d.as_secs()
            ),
        },
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
