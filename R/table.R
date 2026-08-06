# Table handles and metadata.

#' @noRd
new_icebergr_table <- function(ptr, catalog) {
  structure(
    list(ptr = ptr, catalog = catalog),
    class = "icebergr_table"
  )
}

#' @noRd
check_table <- function(x, arg = "tbl", call = rlang::caller_env()) {
  if (!inherits(x, "icebergr_table")) {
    abort(
      paste0("`", arg, "` must be a table opened with `icebergr_table()`."),
      call = call
    )
  }
  invisible(NULL)
}

#' Open an Iceberg table
#'
#' @param catalog An `icebergr_catalog` from [icebergr_catalog()].
#' @param table A table identifier, `"namespace.table"`. Nested namespaces are
#'   written `"a.b.table"`.
#'
#' @return An `icebergr_table` handle.
#'
#' @details
#' The handle is a snapshot of the table's metadata at the moment it was opened.
#' Appending with [icebergr_append()] returns an updated handle rather than
#' mutating this one, so a handle always reads a consistent view.
#'
#' @examples
#' \dontrun{
#' catalog <- icebergr_catalog("rest", uri = "https://catalog.example.com")
#' tbl <- icebergr_table(catalog, "db.events")
#' icebergr_schema(tbl)
#' }
#' @export
icebergr_table <- function(catalog, table) {
  check_catalog(catalog)
  ident <- parse_identifier(table)
  ptr <- rs_table_open(catalog$ptr, ident$namespace, ident$name)
  new_icebergr_table(ptr, catalog)
}

#' The schema of an Iceberg table
#'
#' @param tbl An `icebergr_table` from [icebergr_table()].
#'
#' @return A tibble with one row per top-level field: `field_id`, `name`,
#'   `type` (the Iceberg type), `required` and `doc`.
#'
#' @examples
#' \dontrun{
#' icebergr_schema(tbl)
#' }
#' @export
icebergr_schema <- function(tbl) {
  check_table(tbl)
  as_result_tbl(rs_table_schema(tbl$ptr))
}

#' The partition specification of an Iceberg table
#'
#' @param tbl An `icebergr_table` from [icebergr_table()].
#'
#' @return A tibble with one row per partition field: `spec_id`, `field_id`,
#'   `name`, `transform`, `source_id` and `source_name`. An unpartitioned table
#'   returns zero rows.
#'
#' @details
#' Only the table's *default* (current) partition spec is reported. Reading
#' historical specs would be part of partition evolution, which is out of scope
#' for this version.
#'
#' @examples
#' \dontrun{
#' icebergr_partitions(tbl)
#' }
#' @export
icebergr_partitions <- function(tbl) {
  check_table(tbl)
  as_result_tbl(rs_table_partitions(tbl$ptr))
}

#' @noRd
table_columns <- function(tbl) {
  rs_table_schema(tbl$ptr)$name
}

#' @export
print.icebergr_table <- function(x, ...) {
  ident <- rs_table_identifier(x$ptr)
  schema <- rs_table_schema(x$ptr)
  snapshot <- rs_table_current_snapshot(x$ptr)
  partitions <- rs_table_partitions(x$ptr)

  cat("<icebergr_table>\n")
  cat("  table:    ", paste(ident, collapse = "."), "\n", sep = "")
  cat("  location: ", rs_table_location(x$ptr), "\n", sep = "")
  cat("  format:   v", rs_table_format_version(x$ptr), "\n", sep = "")
  cat("  snapshot: ", if (is.null(snapshot)) "<none>" else snapshot, "\n", sep = "")

  cat("  columns:  ", length(schema$name), "\n", sep = "")
  n_show <- min(length(schema$name), 10L)
  if (n_show > 0L) {
    for (i in seq_len(n_show)) {
      cat("    ", schema$name[[i]], " <", schema$type[[i]], ">",
        if (schema$required[[i]]) " [required]" else "", "\n",
        sep = ""
      )
    }
    if (length(schema$name) > n_show) {
      cat("    ... and ", length(schema$name) - n_show, " more\n", sep = "")
    }
  }

  if (length(partitions$name)) {
    cat("  partitioned by: ",
      paste0(partitions$transform, "(", partitions$source_name, ")", collapse = ", "),
      "\n",
      sep = ""
    )
  }

  invisible(x)
}
