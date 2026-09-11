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
        i = "icebergr needs a Rust toolchain: https://rust-lang.org/tools/install/"
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

#' A filesystem path in the form Iceberg treats as a location
#'
#' Iceberg locations are slash-separated, and `iceberg-rust` parses one by
#' splitting on `/`: it wants the directory to end in `/metadata` and the file to
#' be `<version>-<uuid>.metadata.json`, and it derives the *next* metadata file
#' name the same way when committing. `normalizePath()` on Windows returns
#' `C:\\warehouse\\db\\events\\metadata\\...`, which contains no `/` at all, so a
#' table registered from one read perfectly well and then failed every commit with
#' "Invalid metadata location". Windows file APIs accept forward slashes, so this
#' only changes the separator.
#'
#' Left alone off Windows, where a backslash is a legal character in a file name
#' and rewriting it would corrupt the path. `windows` is an argument so that both
#' branches are testable from either platform.
#' @noRd
as_iceberg_location <- function(path, windows = .Platform$OS.type == "windows") {
  if (windows) gsub("\\", "/", path, fixed = TRUE) else path
}

#' Is an environment variable set to something meaning "yes"?
#'
#' `as.logical()` alone is not enough: it maps "true", "TRUE" and "T" but
#' returns NA for "1", "yes" and "on", which are exactly what a person setting
#' a flag in a shell profile or a CI file tends to write. Silently reading "1"
#' as "not set" makes a documented escape hatch look broken.
#' @noRd
env_flag <- function(name) {
  value <- tolower(trimws(Sys.getenv(name, unset = "")))
  value %in% c("true", "t", "yes", "y", "on", "1")
}

#' Is `x` a path on this machine, rather than a remote location or a bare name?
#'
#' A warehouse can be a directory, an `s3://` URL, or -- for a REST catalog --
#' a name the server resolves. Only the first can be compared against a local
#' file path. A Windows drive letter is `C:/`, never `C://`, so requiring the
#' double slash does not misread one as a scheme.
#' @noRd
is_local_dir <- function(x) {
  !grepl("^[A-Za-z][A-Za-z0-9+.-]*://", x)
}

#' Is `path` inside `root`?
#'
#' Both are expected to have been through `normalizePath()` and
#' `as_iceberg_location()` already, so `..` and symlinks are resolved and the
#' separators are forward slashes.
#'
#' The trailing separator is load-bearing: a plain `startsWith()` says
#' `/warehouse-old/x` is inside `/warehouse`, which is exactly the kind of
#' near-miss a confinement check exists to catch. Windows path comparison is
#' case-insensitive, and `windows` is an argument so both branches are testable
#' from either platform.
#' @noRd
is_inside <- function(path, root, windows = .Platform$OS.type == "windows") {
  if (windows) {
    path <- tolower(path)
    root <- tolower(root)
  }
  root <- sub("/+$", "", root)
  identical(path, root) || startsWith(path, paste0(root, "/"))
}

#' The index in `columns` of the column `name` refers to, or NA for none
#'
#' An exact match always wins, even when matching case-insensitively. Iceberg
#' column names are case-sensitive, so a schema may legitimately hold both `id`
#' and `ID` -- Spark will create one -- and `match(tolower(name),
#' tolower(columns))` then returned whichever came first. Asking for `ID` under
#' `case_sensitive = FALSE` therefore read the column called `id`: the wrong
#' column's data for a name that was an exact match for the right one. As a
#' filter it was worse than wrong, it was empty, since `ID > 250` bound to `id`
#' and matched nothing.
#'
#' With no exact match and more than one case-insensitive candidate the name is
#' genuinely ambiguous. There is no defensible pick, and picking silently is how
#' the above happened, so that is an error naming the candidates.
#' @noRd
column_index <- function(name, columns, case_sensitive = TRUE,
                         call = rlang::caller_env()) {
  exact <- match(name, columns)
  if (!is.na(exact)) {
    return(exact)
  }
  if (case_sensitive) {
    return(NA_integer_)
  }

  candidates <- which(tolower(columns) == tolower(name))
  if (!length(candidates)) {
    return(NA_integer_)
  }
  if (length(candidates) > 1L) {
    abort(
      c(
        paste0(
          encodeString(name, quote = "`"), " matches ", length(candidates),
          " columns when case is ignored: ",
          paste(columns[candidates], collapse = ", "), "."
        ),
        i = "Name one of them exactly, or use `case_sensitive = TRUE`."
      ),
      class = "icebergr_ambiguous_column",
      call = call
    )
  }
  candidates[[1L]]
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
