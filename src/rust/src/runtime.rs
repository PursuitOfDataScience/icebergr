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

use tokio::runtime::{Builder, Runtime as TokioRuntime};

static TOKIO: OnceLock<TokioRuntime> = OnceLock::new();

/// The shared runtime, started on first use.
///
/// Two worker threads by default. That keeps us inside CRAN's limit on
/// parallelism during checks and is ample for work that is almost entirely IO
/// bound; it can be raised for large scans with `ICEBERGR_WORKER_THREADS`.
fn tokio_runtime() -> &'static TokioRuntime {
    TOKIO.get_or_init(|| {
        let workers = std::env::var("ICEBERGR_WORKER_THREADS")
            .ok()
            .and_then(|v| v.parse::<usize>().ok())
            .filter(|n| *n > 0)
            .unwrap_or(2);

        Builder::new_multi_thread()
            .worker_threads(workers)
            .thread_name("icebergr")
            .enable_all()
            .build()
            .expect("icebergr: could not start the tokio runtime")
    })
}

/// Run `fut` to completion on the shared runtime.
pub fn block_on<F: Future>(fut: F) -> F::Output {
    tokio_runtime().block_on(fut)
}

/// The iceberg-rust runtime handle wrapping our runtime.
///
/// Passed explicitly to every catalog builder. `Runtime::current()` would
/// otherwise be called inside `load()`, which only works when already inside a
/// runtime context and would tie the catalog to whatever happened to be current.
pub fn iceberg_runtime() -> iceberg::Runtime {
    iceberg::Runtime::new(tokio_runtime())
}
