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

#' Normalise POSIXct columns to UTC
#'
#' Iceberg's `timestamptz` is UTC by definition, and `iceberg-rust` accepts only
#' `Timestamp(unit, None)` or `Timestamp(unit, "UTC" | "+00:00")` when it
#' converts an Arrow schema; anything else, `Timestamp(us, "America/New_York")`
#' included, falls through to "unsupported Arrow data type". A `POSIXct` is an
#' absolute instant and `tzone` only says how to display it, so relabelling the
#' attribute changes the representation without moving the moment in time --
#' which is exactly the "instant preserved; normalised to UTC" behaviour the
#' type-fidelity table documents.
#'
#' Every `POSIXct` is relabelled, not only those carrying a zone. A `POSIXct`
#' with no `tzone`, or with `""`, is R's "local time is implied" form, and
#' nanoarrow resolves that to the *session's* zone -- `Timestamp(us,
#' "America/Chicago")` on a machine in Chicago -- rather than to a zone-less
#' Arrow timestamp. Leaving it alone would therefore not produce Iceberg's
#' zone-less `timestamp`; it would produce a schema Iceberg refuses, and one
#' whose Iceberg type depended on where the machine happened to be.
#'
#' Recursive, because a `struct` is a data frame column and a `POSIXct` one level
#' down needs this every bit as much as a top-level one -- and silently: a naive
#' `POSIXct` inside a struct reached nanoarrow as the session's zone, so
#' `icebergr_create_table()` failed with "Unsupported Arrow data type:
#' Timestamp(us, \"America/Chicago\")" on the same data frame that works on a
#' machine set to UTC. `list` and `map` are deliberately not descended into, for
#' the same reason `rewrite_int64()` leaves them alone: their columns are not
#' data frames, so there is no column to substitute.
#' @noRd
normalise_timestamps <- function(x) {
  if (!is.data.frame(x)) {
    return(x)
  }
  for (nm in names(x)) {
    if (inherits(x[[nm]], "POSIXct")) {
      attr(x[[nm]], "tzone") <- "UTC"
    } else if (is.data.frame(x[[nm]])) {
      x[[nm]] <- normalise_timestamps(x[[nm]])
    }
  }
  x
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
    nanoarrow::infer_nanoarrow_schema(normalise_timestamps(x))
  }
  list(schema = schema, addr = ptr_addr(schema))
}

#' Export an R data frame as an Arrow stream Rust can consume
#' @noRd
export_stream <- function(x) {
  stream <- nanoarrow::as_nanoarrow_array_stream(normalise_timestamps(x))
  list(stream = stream, addr = ptr_addr(stream))
}

#' A conversion prototype that keeps 64-bit integers exact
#'
#' nanoarrow converts an Arrow `int64` to an R `double` unless told otherwise,
#' and a double is only lossless to 2^53. Iceberg's `long` is a full 64-bit
#' integer, so an id or a count past that point comes back silently rounded --
#' 9007199254740993 reads as 9007199254740992. `bit64::integer64` is the only R
#' type that holds one exactly, so `int64` columns are asked for as that.
#'
#' `NULL` means "use nanoarrow's own defaults", which is what happens when bit64
#' is not installed (it is only suggested) and what we fall back to if the
#' schema cannot be inspected. The fallback is exactly the previous behaviour,
#' so this can only ever be an improvement or a no-op.
#' @noRd
int64_ptype <- function(schema) {
  if (!requireNamespace("bit64", quietly = TRUE)) {
    return(NULL)
  }
  tryCatch(
    rewrite_int64(nanoarrow::infer_nanoarrow_ptype(schema), schema$children),
    error = function(e) NULL
  )
}

#' Retype the int64 columns of an inferred prototype, at any depth
#'
#' Recursive, because a `long` inside a `struct` loses precision in exactly the
#' way a top-level one does, and silently: a struct field holding
#' 9007199254740993 read back as 9007199254740992 while the same value in a
#' top-level column came back exact. A struct arrives in R as a data frame
#' column, so the fix is the same rewrite applied one level down.
#'
#' Returns `NULL` when there is no `int64` anywhere in the subtree, which is how
#' the caller decides to leave nanoarrow's defaults alone entirely.
#'
#' `list` and `map` are deliberately not descended into. Their prototypes are not
#' data frames, so retyping an element would mean constructing a `list_of` ptype
#' rather than substituting a column, and a `list<long>` remains as nanoarrow
#' converts it. That is the behaviour these columns already had; the struct case
#' is the one Iceberg users actually hit, and the one now documented as
#' supported.
#' @noRd
rewrite_int64 <- function(ptype, children) {
  # A schema whose prototype is not a data frame, or does not line up with its
  # own children, is not something to guess at.
  if (!is.data.frame(ptype) || length(children) != length(ptype)) {
    return(NULL)
  }

  changed <- FALSE
  for (i in seq_along(children)) {
    # Arrow C data interface format strings: "l" is int64, "+s" is struct.
    format <- children[[i]]$format
    if (identical(format, "l")) {
      ptype[[i]] <- bit64::integer64()
      changed <- TRUE
    } else if (identical(format, "+s")) {
      nested <- rewrite_int64(ptype[[i]], children[[i]]$children)
      if (!is.null(nested)) {
        ptype[[i]] <- nested
        changed <- TRUE
      }
    }
  }

  if (changed) ptype else NULL
}

# The zone names that mean UTC but are not the string "UTC". iceberg-rust writes
# "+00:00"; the rest are what other engines and Arrow implementations use.
utc_synonyms <- c("+00:00", "+0000", "Z", "z", "GMT", "Etc/UTC", "UTC+0", "utc")

#' Give a UTC timestamp column R's own name for UTC
#'
#' `iceberg-rust` labels a `timestamptz` column `"+00:00"` rather than `"UTC"`.
#' Both mean the same zone, but R does not treat them as the same *string*:
#' comparing a column read back from Iceberg against an ordinary
#' `as.POSIXct(..., tz = "UTC")` warns "'tzone' attributes are inconsistent", and
#' `"+00:00"` is not a name the platform's zone database recognises, so
#' formatting it is at the mercy of the C library. Relabelling touches the
#' attribute only, never the instant.
#'
#' Recursive for the same reason `normalise_timestamps()` is: a `struct` arrives
#' as a data frame column, and a `timestamptz` inside one kept `"+00:00"`, so the
#' warning this exists to prevent fired on exactly the nested columns nothing had
#' looked at.
#' @noRd
canonicalise_utc <- function(x) {
  if (!is.data.frame(x)) {
    return(x)
  }
  for (nm in names(x)) {
    if (inherits(x[[nm]], "POSIXct")) {
      tz <- attr(x[[nm]], "tzone")
      if (length(tz) == 1L && !is.na(tz) && tz %in% utc_synonyms) {
        attr(x[[nm]], "tzone") <- "UTC"
      }
    } else if (is.data.frame(x[[nm]])) {
      x[[nm]] <- canonicalise_utc(x[[nm]])
    }
  }
  x
}

#' Materialise an Arrow stream into a tibble
#'
#' `limit` stops pulling batches once enough rows have been seen. That is not
#' predicate pushdown -- the scan is still planned over the same files -- but it
#' does avoid decoding batches nobody asked for.
#' @noRd
collect_stream <- function(stream, limit = NULL) {
  schema <- stream$get_schema()
  ptype <- int64_ptype(schema)

  as_tbl <- function(x) tibble::as_tibble(canonicalise_utc(x))

  convert_stream <- function(x) {
    if (is.null(ptype)) {
      nanoarrow::convert_array_stream(x)
    } else {
      nanoarrow::convert_array_stream(x, to = ptype)
    }
  }
  # Still needs the right columns and types, so take the schema and zero rows.
  no_rows <- function() {
    convert_stream(nanoarrow::basic_array_stream(list(), schema = schema))
  }

  if (is.null(limit)) {
    return(as_tbl(convert_stream(stream)))
  }

  # A double, not as.integer(): a limit past .Machine$integer.max coerced to NA,
  # and the `limit == 0L` below then failed with "missing value where TRUE/FALSE
  # needed" rather than reading the table. Nothing here needs an integer -- the
  # value is only ever compared and passed to seq_len() -- and a double counts
  # whole numbers exactly far past any row count that fits in memory.
  limit <- as.numeric(limit)
  if (limit == 0) {
    return(as_tbl(no_rows()))
  }

  chunks <- list()
  # Double, not integer: `seen + nrow(piece)` on two integers overflows to NA
  # past 2^31 rows, and the `seen >= limit` below would then error rather than
  # stop. Counting in a double costs nothing and is exact well past any row
  # count that would fit in memory.
  seen <- 0
  repeat {
    array <- stream$get_next()
    if (is.null(array)) break
    piece <- if (is.null(ptype)) {
      nanoarrow::convert_array(array)
    } else {
      nanoarrow::convert_array(array, to = ptype)
    }
    chunks[[length(chunks) + 1L]] <- piece
    seen <- seen + nrow(piece)
    if (seen >= limit) break
  }

  if (length(chunks) == 0L) {
    return(as_tbl(no_rows()))
  }

  out <- if (length(chunks) == 1L) chunks[[1L]] else do.call(rbind, chunks)
  if (nrow(out) > limit) out <- out[seq_len(limit), , drop = FALSE]
  as_tbl(out)
}
