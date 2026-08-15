# Shared helpers.

# Caches the result of the first successful call into the compiled library, so
# the availability check costs nothing after the first use.
the <- new.env(parent = emptyenv())

#' Fail clearly when the compiled Rust library is unusable
#'
#' A package that loaded but cannot reach its own compiled routines is almost
#' always a half-finished source install -- a build that failed after the R code
#' was copied into place. Saying so beats a bare "object not found".
#' @noRd
ensure_rust <- function(call = rlang::caller_env()) {
  if (isTRUE(the$rust_ok)) {
    return(invisible(TRUE))
  }

  info <- tryCatch(rs_build_info(), error = function(e) e)
  if (inherits(info, "error")) {
    abort(
      c(
        "The compiled Rust component of icebergr is not available.",
        i = "The package was loaded, but its native routines could not be called.",
        x = paste("Underlying error:", conditionMessage(info)),
        i = paste(
          "This usually means the source install did not finish. Reinstall with",
          "`install.packages(\"icebergr\", type = \"source\")` and check the build",
          "log for cargo errors."
        ),
        i = "icebergr needs a Rust toolchain: https://www.rust-lang.org/tools/install"
      ),
      class = "icebergr_rust_unavailable",
      call = call
    )
  }

  the$rust_ok <- TRUE
  the$build_info <- info
  invisible(TRUE)
}

#' @noRd
build_info <- function() {
  ensure_rust()
  the$build_info
}

#' Split a dotted table identifier into namespace levels and a table name
#'
#' `"db.events"` becomes namespace `"db"` and name `"events"`; `"a.b.events"`
#' becomes namespace `c("a", "b")`. A name with no namespace is an error, since
#' Iceberg tables always live in one.
#' @noRd
parse_identifier <- function(x, call = rlang::caller_env()) {
  if (!is.character(x) || length(x) != 1L || is.na(x) || !nzchar(x)) {
    abort("`table` must be a single non-empty string.", call = call)
  }

  parts <- strsplit(x, ".", fixed = TRUE)[[1L]]
  parts <- parts[nzchar(parts)]

  if (length(parts) < 2L) {
    abort(
      c(
        paste0("Could not read ", encodeString(x, quote = "\""), " as a table identifier."),
        i = "Use \"namespace.table\", for example \"db.events\".",
        i = "Nested namespaces are written \"a.b.table\"."
      ),
      call = call
    )
  }

  list(
    namespace = parts[-length(parts)],
    name = parts[[length(parts)]]
  )
}

#' @noRd
check_string <- function(x, arg, allow_null = TRUE, call = rlang::caller_env()) {
  if (is.null(x)) {
    if (allow_null) {
      return(invisible(NULL))
    }
    abort(paste0("`", arg, "` must not be NULL."), call = call)
  }
  if (!is.character(x) || length(x) != 1L || is.na(x)) {
    abort(paste0("`", arg, "` must be a single string."), call = call)
  }
  invisible(NULL)
}

#' @noRd
check_bool <- function(x, arg, call = rlang::caller_env()) {
  if (!is.logical(x) || length(x) != 1L || is.na(x)) {
    abort(paste0("`", arg, "` must be TRUE or FALSE."), call = call)
  }
  invisible(NULL)
}

#' @param max Optional inclusive upper bound, for a count that has to survive
#'   being narrowed to a C `int` on the way into Rust. Without it, `as.integer()`
#'   turns anything past `.Machine$integer.max` into `NA` and the failure
#'   surfaces much later, as "Must not be NA".
#' @noRd
check_count <- function(x, arg, max = NULL, call = rlang::caller_env()) {
  if (is.null(x)) {
    return(invisible(NULL))
  }
  if (!is.numeric(x) || length(x) != 1L || is.na(x) || x < 0 || x != trunc(x)) {
    abort(paste0("`", arg, "` must be a single non-negative whole number, or NULL."), call = call)
  }
  if (!is.null(max) && x > max) {
    abort(
      paste0(
        "`", arg, "` must be at most ", format(max, scientific = FALSE), "."
      ),
      call = call
    )
  }
  invisible(NULL)
}

#' Fail clearly on a handle whose Rust object did not survive the trip
#'
#' An `icebergr_catalog` or `icebergr_table` holds an external pointer. R
#' serialises the pointer's box but never the Rust value behind it, so a handle
#' that has been through `saveRDS()`, restored from `.RData`, or sent to a
#' serialising parallel worker comes back pointing at nothing. Dereferencing it
#' is caught in Rust, but the message describes the mechanism rather than the
#' mistake.
#' @noRd
check_live_ptr <- function(x, what, call = rlang::caller_env()) {
  if (!inherits(x, "externalptr") || rs_ptr_is_null(x)) {
    abort(
      c(
        paste0("This ", what, " handle is no longer usable."),
        i = paste(
          "Handles hold a pointer into the Rust side, which does not survive",
          "saveRDS(), a restored .RData, or a parallel worker that serialises",
          "its inputs."
        ),
        i = "Open it again in this session with `icebergr_catalog()`."
      ),
      class = "icebergr_dead_handle",
      call = call
    )
  }
  invisible(NULL)
}

#' Build a tibble from the parallel vectors Rust returns
#' @noRd
as_result_tbl <- function(x) {
  tibble::as_tibble(x)
}

#' Snapshot ids are carried as character to survive R's 53-bit numerics
#' @noRd
as_snapshot_id <- function(x, arg = "snapshot_id", call = rlang::caller_env()) {
  if (is.null(x)) {
    return(NULL)
  }
  if (length(x) != 1L || is.na(x)) {
    abort(paste0("`", arg, "` must be a single snapshot id."), call = call)
  }

  if (is.character(x)) {
    return(x)
  }

  # Checked before the numeric branch: bit64::integer64 is a double underneath,
  # so it satisfies is.numeric(), but it holds a 64-bit integer *exactly*. The
  # "too large to be represented exactly" refusal below is simply untrue of it,
  # and icebergr_snapshots() ids past 2^53 are precisely the ones a user is
  # likely to have converted with bit64::as.integer64().
  if (inherits(x, "integer64")) {
    return(format(x, scientific = FALSE))
  }

  if (is.numeric(x)) {
    # A snapshot id is a random 64-bit integer. Anything past 2^53 has already
    # lost precision by the time it gets here, so refuse rather than read the
    # wrong snapshot.
    if (x != trunc(x)) {
      abort(paste0("`", arg, "` must be a whole number."), call = call)
    }
    if (abs(x) > 2^53) {
      abort(
        c(
          paste0("`", arg, "` is too large to be represented exactly as a number."),
          i = "Pass it as a string instead, e.g. snapshot_id = \"7434046026776969423\".",
          i = "icebergr_snapshots() returns ids as character for this reason."
        ),
        call = call
      )
    }
    return(format(x, scientific = FALSE))
  }

  abort(paste0("`", arg, "` must be a string or a number."), call = call)
}
