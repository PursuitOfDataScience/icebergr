//! The Arrow interchange layer.
//!
//! Data crosses the Rust/R boundary as an `ArrowArrayStream` through the Arrow
//! C stream interface, so batches are handed over by pointer rather than
//! serialised. R allocates the stream struct (via nanoarrow) and passes us its
//! address; we write an exported stream into it, or consume one from it.
//!
//! Addresses travel as decimal strings rather than as R doubles. A double holds
//! only 53 bits exactly, and while user-space pointers happen to fit today,
//! there is no reason to build that assumption in.

use std::panic::AssertUnwindSafe;

use arrow::ffi_stream::{ArrowArrayStreamReader, FFI_ArrowArrayStream};
use arrow_array::{RecordBatch, RecordBatchReader};
use arrow_schema::{ArrowError, SchemaRef};
use extendr_api::Error as RError;
use futures::StreamExt;
use iceberg::scan::ArrowRecordBatchStream;

use crate::errors::{RResult, ctx};
use crate::runtime::block_on;

/// Parse a pointer address supplied by R.
fn parse_addr(addr: &str) -> RResult<usize> {
    let s = addr.trim();
    let parsed = if let Some(hex) = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
        usize::from_str_radix(hex, 16)
    } else {
        s.parse::<usize>()
    };
    let p = parsed.map_err(|e| ctx(&format!("not a valid Arrow stream address ({s:?})"), e))?;
    if p == 0 {
        return Err(RError::Other(
            "received a null Arrow stream pointer from R".to_string(),
        ));
    }
    Ok(p)
}

/// Adapts an async Iceberg record batch stream to the synchronous
/// `RecordBatchReader` that the C stream interface requires.
///
/// Each call to `next` blocks the calling thread -- R's thread -- until the
/// next batch is ready. That keeps memory bounded to one batch at a time
/// instead of collecting the whole scan up front, which matters for tables
/// larger than memory.
pub struct BlockingBatchReader {
    schema: SchemaRef,
    /// The batch consumed by `new` while establishing the schema.
    pending: Option<RecordBatch>,
    stream: Option<ArrowRecordBatchStream>,
}

impl BlockingBatchReader {
    /// `fallback_schema` is used only when the scan yields no batches at all,
    /// in which case there is nothing to read a schema from.
    pub fn new(stream: ArrowRecordBatchStream, fallback_schema: SchemaRef) -> RResult<Self> {
        let mut stream = stream;

        // Pull one batch eagerly and take the schema from it. Reconstructing the
        // schema from the Iceberg schema instead risks disagreeing with the
        // batches over field order or metadata, and a C stream whose schema does
        // not match its arrays is undefined behaviour on the consumer side.
        match block_on(stream.next()) {
            Some(Ok(batch)) => Ok(Self {
                schema: batch.schema(),
                pending: Some(batch),
                stream: Some(stream),
            }),
            Some(Err(e)) => Err(ctx("scan failed", e)),
            None => Ok(Self {
                schema: fallback_schema,
                pending: None,
                stream: None,
            }),
        }
    }

    /// The body of `next`, minus the panic guard around it.
    fn next_batch(&mut self) -> Option<std::result::Result<RecordBatch, ArrowError>> {
        if let Some(batch) = self.pending.take() {
            return Some(Ok(batch));
        }
        let stream = self.stream.as_mut()?;
        match block_on(stream.next()) {
            Some(Ok(batch)) => Some(Ok(batch)),
            Some(Err(e)) => {
                // Do not keep polling a stream that has already failed.
                self.stream = None;
                Some(Err(ArrowError::ExternalError(Box::new(e))))
            }
            None => {
                self.stream = None;
                None
            }
        }
    }
}

impl Iterator for BlockingBatchReader {
    type Item = std::result::Result<RecordBatch, ArrowError>;

    fn next(&mut self) -> Option<Self::Item> {
        // This runs inside the C stream's `get_next` callback, which arrow-rs
        // declares `extern "C"` and does not guard. An unwind out of an
        // `extern "C"` frame aborts the process -- taking the whole R session
        // down, unsaved work included -- so a panic anywhere below (in
        // iceberg-rust, in a Parquet decoder, in tokio) has to be turned into an
        // ordinary error here rather than allowed to escape.
        match std::panic::catch_unwind(AssertUnwindSafe(|| self.next_batch())) {
            Ok(item) => item,
            Err(payload) => {
                // A panicked stream is not safe to poll again.
                self.stream = None;
                self.pending = None;
                let what = panic_message(&*payload);
                // ComputeError rather than ExternalError: the latter wants a
                // Send + Sync payload, which extendr's Error is not (it can hold
                // a SEXP).
                Some(Err(ArrowError::ComputeError(format!(
                    "icebergr: the Iceberg scan panicked while reading: {what}"
                ))))
            }
        }
    }
}

/// Recover whatever text a panic payload carries, for the error message.
fn panic_message(payload: &(dyn std::any::Any + Send)) -> String {
    if let Some(s) = payload.downcast_ref::<&str>() {
        (*s).to_string()
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "panic with no message".to_string()
    }
}

impl RecordBatchReader for BlockingBatchReader {
    fn schema(&self) -> SchemaRef {
        self.schema.clone()
    }
}

/// Write an exported Arrow stream into the struct R allocated at `addr`.
pub fn export_reader(addr: &str, reader: Box<dyn RecordBatchReader + Send>) -> RResult<()> {
    let ptr = parse_addr(addr)? as *mut FFI_ArrowArrayStream;
    let stream = FFI_ArrowArrayStream::new(reader);

    // SAFETY: `addr` is the address of a freshly allocated, released
    // ArrowArrayStream owned by R (nanoarrow_allocate_array_stream). Writing
    // over a released stream is what the C data interface prescribes, and
    // write_unaligned avoids assuming R's allocator aligned it for us.
    unsafe { std::ptr::write_unaligned(ptr, stream) };
    Ok(())
}

/// Read an Arrow schema that R exported at `addr`, without taking ownership.
///
/// Borrowed rather than moved on purpose: the struct still belongs to R, which
/// will release it when its nanoarrow object is collected. Moving it out here
/// would leave both sides believing they own it.
pub fn import_schema(addr: &str) -> RResult<arrow_schema::Schema> {
    let ptr = parse_addr(addr)? as *const arrow::ffi::FFI_ArrowSchema;

    // SAFETY: `addr` is the address of a populated ArrowSchema owned by R, and
    // the reference does not outlive this function.
    let ffi = unsafe { &*ptr };
    arrow_schema::Schema::try_from(ffi).map_err(|e| ctx("could not read the Arrow schema", e))
}

/// Take ownership of an Arrow stream that R has populated at `addr`.
pub fn import_reader(addr: &str) -> RResult<ArrowArrayStreamReader> {
    let ptr = parse_addr(addr)? as *mut FFI_ArrowArrayStream;

    // SAFETY: `addr` points at an ArrowArrayStream that the R side has filled
    // in from a data frame or Arrow object. from_raw moves the stream out and
    // marks the source released, so ownership is unambiguous afterwards.
    unsafe { ArrowArrayStreamReader::from_raw(ptr) }
        .map_err(|e| ctx("could not import the Arrow stream from R", e))
}
