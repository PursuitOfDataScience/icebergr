# Reads, with pushdown.

#' Scan an Iceberg table
#'
#' Describes a read without performing it. Pass the result to
#' [icebergr_collect()] or [as.data.frame()] to materialise it.
#'
#' @param tbl An `icebergr_table` from [icebergr_table()].
#' @param filter An unquoted R expression, pushed down to Iceberg. See
#'   *Pushdown* below for what can be expressed.
#' @param select Character vector of columns to read. `NULL` reads all of them.
#' @param limit Maximum number of rows to return, or `NULL` for no limit. See
#'   *Pushdown* for an important caveat.
#' @param snapshot_id Read this snapshot instead of the current one. A character
#'   id from [icebergr_snapshots()].
#' @param as_of Read the table as it was at this time, a `POSIXct` or `Date`.
#'   Resolved to the newest snapshot committed at or before it. Cannot be
#'   combined with `snapshot_id`.
#' @param batch_size Rows per Arrow batch, or `NULL` for the default. Affects
#'   memory use, not results.
#' @param case_sensitive Whether column names in `filter` and `select` are
#'   matched case-sensitively. When `FALSE`, each name is resolved to the
#'   table's own spelling before the scan is planned, so `select = "ID"` reads
#'   the column the table calls `id`.
#'
#' @return An `icebergr_scan` object.
#'
#' @section Pushdown:
#' `filter` and `select` are pushed down into scan planning, which is the whole
#' performance argument for Iceberg over reading raw Parquet: manifests carry
#' per-file statistics, so entire files and row groups are skipped before any
#' bytes are read. Inspect the effect with [icebergr_scan_plan()].
#'
#' `limit` is **not** pushed down: `iceberg-rust` has no row limit in its scan
#' API, so the same files are planned and rows are counted as batches arrive.
#' It bounds how much is decoded and converted, not how much is planned.
#'
#' Filters may use `==`, `!=`, `<`, `<=`, `>`, `>=`, `&`, `|`, `!`, `%in%`,
#' `is.na()`, `is.nan()` and `startsWith()`. A bare name is read as a column when
#' the table has a column of that name, and otherwise evaluated in the calling
#' environment, so `filter = year == target` works with a local `target`.
#' Anything more elaborate should be applied in R after collecting.
#'
#' @examples
#' tbl <- icebergr_example_table(rows = 10)
#'
#' # Projection and predicate pushdown
#' scan <- icebergr_scan(tbl, filter = id > 1000 & amount > 900, select = c("id", "amount"))
#' scan
#' icebergr_collect(scan)
#'
#' # A local variable is usable in a filter: a bare name is read as a column
#' # only when the table has one of that name.
#' cutoff <- 1005
#' icebergr_collect(icebergr_scan(tbl, filter = id > cutoff, select = "id"))
#'
#' # Time travel, to the state before the second append
#' history <- icebergr_snapshots(tbl)
#' nrow(icebergr_collect(icebergr_scan(tbl, snapshot_id = history$snapshot_id[[1]])))
#' nrow(icebergr_collect(icebergr_scan(tbl, as_of = history$timestamp[[1]])))
#' @export
icebergr_scan <- function(tbl,
                          filter = NULL,
                          select = NULL,
                          limit = NULL,
                          snapshot_id = NULL,
                          as_of = NULL,
                          batch_size = NULL,
                          case_sensitive = TRUE) {
  check_table(tbl)
  check_count(limit, "limit")
  check_count(batch_size, "batch_size")
  check_bool(case_sensitive, "case_sensitive")

  if (!is.null(snapshot_id) && !is.null(as_of)) {
    abort(c(
      "`snapshot_id` and `as_of` cannot both be given.",
      i = "They are two ways of naming the same thing; pick one."
    ))
  }

  if (!is.null(select)) {
    if (!is.character(select) || anyNA(select) || !all(nzchar(select))) {
      abort("`select` must be a character vector of column names.")
    }
    available <- table_columns(tbl)
    hits <- if (case_sensitive) {
      match(select, available)
    } else {
      match(tolower(select), tolower(available))
    }
    if (anyNA(hits)) {
      abort(c(
        paste0(
          "Cannot select column(s) not in the table: ",
          paste(select[is.na(hits)], collapse = ", "), "."
        ),
        i = paste0("Available columns: ", paste(available, collapse = ", "), ".")
      ))
    }
    # Resolved to the table's own spelling. `iceberg-rust` looks a projected
    # column up case-sensitively whatever the scan's `case_sensitive` setting
    # says, so passing the caller's casing straight through would fail there
    # after being accepted here.
    select <- available[hits]
  }

  snapshot <- if (!is.null(as_of)) {
    snapshot_as_of(tbl, as_of)
  } else {
    as_snapshot_id(snapshot_id)
  }

  # Checked here rather than left to scan planning, for the same reason `select`
  # is: a scan is cheap to build and the mistake is in the call, so reporting it
  # at the call beats reporting it from inside a later collect().
  if (!is.null(snapshot) && is.null(as_of)) {
    known <- icebergr_snapshots(tbl)$snapshot_id
    if (!snapshot %in% known) {
      abort(c(
        paste0("Snapshot ", snapshot, " is not in this table's history."),
        i = if (length(known)) {
          paste0("Available: ", paste(known, collapse = ", "), ".")
        } else {
          "This table has no snapshots yet."
        }
      ))
    }
  }

  filter_expr <- substitute(filter)
  filter_json <- NULL
  if (!is.null(filter_expr)) {
    filter_json <- filter_to_json(
      translate_filter(
        filter_expr, table_columns(tbl), parent.frame(),
        case_sensitive = case_sensitive
      )
    )
  }

  structure(
    list(
      tbl = tbl,
      select = select,
      filter_json = filter_json,
      filter_expr = filter_expr,
      snapshot_id = snapshot,
      limit = limit,
      batch_size = batch_size,
      case_sensitive = case_sensitive
    ),
    class = "icebergr_scan"
  )
}

#' @noRd
check_scan <- function(x, call = rlang::caller_env()) {
  if (!inherits(x, "icebergr_scan")) {
    abort("Expected a scan created by `icebergr_scan()`.", call = call)
  }
  invisible(NULL)
}

#' @noRd
scan_stream <- function(scan) {
  holder <- new_stream()
  rs_scan_to_stream(
    tbl = scan$tbl$ptr,
    select = scan$select,
    filter_json = scan$filter_json,
    snapshot_id = scan$snapshot_id,
    batch_size = if (is.null(scan$batch_size)) NULL else as.integer(scan$batch_size),
    case_sensitive = scan$case_sensitive,
    # Both prunings are what make pushdown worth having; they are on unless a
    # future argument turns them off for debugging.
    row_group_filtering = TRUE,
    row_selection = TRUE,
    stream_addr = holder$addr
  )
  holder$stream
}

#' Materialise a scan or a table
#'
#' @param x An `icebergr_scan` from [icebergr_scan()], or an `icebergr_table`
#'   (equivalent to scanning all of it).
#' @param ... Unused, for S3 consistency.
#'
#' @return A tibble.
#'
#' @details
#' Data crosses from Rust into R over the Arrow C stream interface, so batches
#' are handed over by pointer rather than serialised.
#'
#' If the dplyr package is installed, `dplyr::collect()` also works on these
#' objects.
#'
#' @examples
#' tbl <- icebergr_example_table(rows = 10)
#'
#' # A scan, materialised
#' icebergr_collect(icebergr_scan(tbl, filter = id > 1000, select = c("id", "amount")))
#'
#' # A whole table, materialised
#' icebergr_collect(tbl)
#' @export
icebergr_collect <- function(x, ...) {
  UseMethod("icebergr_collect")
}

#' @rdname icebergr_collect
#' @export
icebergr_collect.icebergr_scan <- function(x, ...) {
  collect_stream(scan_stream(x), limit = x$limit)
}

#' @rdname icebergr_collect
#' @export
icebergr_collect.icebergr_table <- function(x, ...) {
  icebergr_collect(icebergr_scan(x))
}

#' @rdname icebergr_collect
#' @param row.names Unused, for consistency with [base::as.data.frame()].
#' @param optional Unused, for consistency with [base::as.data.frame()].
#' @export
as.data.frame.icebergr_scan <- function(x, row.names = NULL, optional = FALSE, ...) {
  as.data.frame(icebergr_collect(x))
}

#' @rdname icebergr_collect
#' @export
as.data.frame.icebergr_table <- function(x, row.names = NULL, optional = FALSE, ...) {
  as.data.frame(icebergr_collect(x))
}

#' Inspect the file plan for a scan
#'
#' Reports which data files a scan would read, without reading them. This is how
#' pushdown is verified rather than assumed: a filtered scan should plan fewer
#' files, and fewer records, than an unfiltered one.
#'
#' @param scan An `icebergr_scan` from [icebergr_scan()].
#'
#' @return A tibble with one row per planned file task: `data_file_path`,
#'   `record_count`, `file_size_in_bytes`, `start` and `length`.
#'
#'   `record_count` is `NA` for a task covering part of a file, since a partial
#'   read has no meaningful record count from the manifest.
#'
#' @examples
#' tbl <- icebergr_example_table(rows = 10)
#'
#' # The example table has two data files, one per append.
#' all_files <- icebergr_scan_plan(icebergr_scan(tbl))
#' hot_files <- icebergr_scan_plan(icebergr_scan(tbl, filter = id > 1000))
#'
#' nrow(hot_files) < nrow(all_files)
#' sum(hot_files$record_count) < sum(all_files$record_count)
#' @export
icebergr_scan_plan <- function(scan) {
  check_scan(scan)
  as_result_tbl(rs_scan_plan(
    tbl = scan$tbl$ptr,
    select = scan$select,
    filter_json = scan$filter_json,
    snapshot_id = scan$snapshot_id,
    case_sensitive = scan$case_sensitive
  ))
}

#' @export
print.icebergr_scan <- function(x, ...) {
  ident <- rs_table_identifier(x$tbl$ptr)
  cat("<icebergr_scan>\n")
  cat("  table:    ", paste(ident, collapse = "."), "\n", sep = "")
  cat("  select:   ",
    if (is.null(x$select)) "<all columns>" else paste(x$select, collapse = ", "),
    "\n",
    sep = ""
  )
  if (!is.null(x$filter_expr)) {
    cat("  filter:   ", deparse1(x$filter_expr), " (pushed down)\n", sep = "")
  }
  if (!is.null(x$snapshot_id)) {
    cat("  snapshot: ", x$snapshot_id, "\n", sep = "")
  }
  if (!is.null(x$limit)) {
    cat("  limit:    ", x$limit, " (applied after the scan, not pushed down)\n", sep = "")
  }
  cat("  Use icebergr_collect() to read it.\n")
  invisible(x)
}
