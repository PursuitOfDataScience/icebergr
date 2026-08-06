# The Arrow interchange layer, R side.
#
# Data moves between Rust and R as an ArrowArrayStream through the Arrow C stream
# interface. R allocates the stream struct, hands Rust its address, and Rust
# either fills it (reads) or drains it (writes). Nothing is serialised in
# between.
#
# Addresses are passed as character, not numeric: an R double carries 53 bits of
# integer precision and a pointer is 64 bits wide.

#' Allocate an empty Arrow array stream and return it with its address
#' @noRd
new_stream <- function() {
  stream <- nanoarrow::nanoarrow_allocate_array_stream()
  list(stream = stream, addr = ptr_addr(stream))
}

#' @noRd
ptr_addr <- function(x) {
  format(nanoarrow::nanoarrow_pointer_addr_chr(x))
}

#' Export an R object's schema so Rust can read it
#'
#' Returns the nanoarrow schema alongside its address. The schema object must
#' stay alive for as long as Rust holds the address, so it is returned rather
#' than left to the garbage collector.
#' @noRd
export_schema <- function(x) {
  schema <- if (inherits(x, "nanoarrow_schema")) {
    x
  } else {
    nanoarrow::infer_nanoarrow_schema(x)
  }
  list(schema = schema, addr = ptr_addr(schema))
}

#' Export an R data frame as an Arrow stream Rust can consume
#' @noRd
export_stream <- function(x) {
  stream <- nanoarrow::as_nanoarrow_array_stream(x)
  list(stream = stream, addr = ptr_addr(stream))
}

#' Materialise an Arrow stream into a tibble
#'
#' `limit` stops pulling batches once enough rows have been seen. That is not
#' predicate pushdown -- the scan is still planned over the same files -- but it
#' does avoid decoding batches nobody asked for.
#' @noRd
collect_stream <- function(stream, limit = NULL) {
  if (is.null(limit)) {
    return(tibble::as_tibble(nanoarrow::convert_array_stream(stream)))
  }

  limit <- as.integer(limit)
  if (limit == 0L) {
    # Still needs the right columns and types, so take the schema and zero rows.
    empty <- nanoarrow::convert_array_stream(
      nanoarrow::basic_array_stream(list(), schema = stream$get_schema())
    )
    return(tibble::as_tibble(empty))
  }

  chunks <- list()
  seen <- 0L
  repeat {
    array <- stream$get_next()
    if (is.null(array)) break
    piece <- nanoarrow::convert_array(array)
    chunks[[length(chunks) + 1L]] <- piece
    seen <- seen + nrow(piece)
    if (seen >= limit) break
  }

  if (length(chunks) == 0L) {
    out <- nanoarrow::convert_array_stream(
      nanoarrow::basic_array_stream(list(), schema = stream$get_schema())
    )
    return(tibble::as_tibble(out))
  }

  out <- if (length(chunks) == 1L) chunks[[1L]] else do.call(rbind, chunks)
  if (nrow(out) > limit) out <- out[seq_len(limit), , drop = FALSE]
  tibble::as_tibble(out)
}
