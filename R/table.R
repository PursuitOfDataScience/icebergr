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
  check_live_ptr(x$ptr, "table", call = call)
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
#' # A local warehouse, so this runs offline.
#' warehouse <- tempfile("warehouse")
#' dir.create(warehouse)
#' catalog <- icebergr_catalog("memory", warehouse = warehouse)
#' icebergr_create_namespace(catalog, "db")
#' icebergr_create_table(catalog, "db.events", data.frame(id = integer()))
#'
#' tbl <- icebergr_table(catalog, "db.events")
#' icebergr_schema(tbl)
#'
#' \dontrun{
#' # The same call against a REST catalog, which needs a server.
#' catalog <- icebergr_catalog("rest", uri = "https://catalog.example.com")
#' tbl <- icebergr_table(catalog, "db.events")
#' }
#' @export
icebergr_table <- function(catalog, table) {
  check_catalog(catalog)
  ident <- parse_identifier(table)
  ptr <- rs_table_open(catalog$ptr, ident$namespace, ident$name)
  new_icebergr_table(ptr, catalog)
}

#' Whether a table exists in a catalog
#'
#' Asks the catalog directly, so an absent table is an answer rather than an
#' error to be caught.
#'
#' @param catalog An `icebergr_catalog` from [icebergr_catalog()].
#' @param table A table identifier, `"namespace.table"`.
#'
#' @return `TRUE` or `FALSE`.
#'
#' @details
#' A namespace that does not exist gives `FALSE` rather than an error, since it
#' cannot hold the table either way. Any other failure -- an unreachable catalog,
#' a rejected credential -- is still an error, because reporting one of those as
#' "no such table" would be a confident wrong answer.
#'
#' @examples
#' warehouse <- tempfile("warehouse")
#' dir.create(warehouse)
#' catalog <- icebergr_catalog("memory", warehouse = warehouse)
#' icebergr_create_namespace(catalog, "db")
#'
#' icebergr_table_exists(catalog, "db.events")
#' icebergr_create_table(catalog, "db.events", data.frame(id = integer()))
#' icebergr_table_exists(catalog, "db.events")
#' @export
icebergr_table_exists <- function(catalog, table) {
  check_catalog(catalog)
  ident <- parse_identifier(table)
  rs_table_exists(catalog$ptr, ident$namespace, ident$name)
}

#' Re-read a table's metadata from its catalog
#'
#' A table handle is a snapshot of the metadata as it was when the handle was
#' opened, which is what makes a read consistent. That also means a handle never
#' sees a commit made after it: [icebergr_append()] hands back an updated handle
#' for your own writes, but a commit from another session, process or engine is
#' invisible until the metadata is read again. This is how to do that without
#' going back to the catalog by name.
#'
#' @param tbl An `icebergr_table` from [icebergr_table()].
#'
#' @return A new `icebergr_table` handle seeing the table's current state. The
#'   handle passed in is unchanged, so reassign it:
#'   `tbl <- icebergr_reload(tbl)`.
#'
#' @examples
#' warehouse <- tempfile("warehouse")
#' dir.create(warehouse)
#' catalog <- icebergr_catalog("memory", warehouse = warehouse)
#' icebergr_create_namespace(catalog, "db")
#' events <- data.frame(id = 1:3L)
#' tbl <- icebergr_create_table(catalog, "db.events", events)
#'
#' # A second handle on the same table, as another session would hold.
#' stale <- icebergr_table(catalog, "db.events")
#' tbl <- icebergr_append(tbl, events)
#'
#' # The second handle still sees the table as it was when it was opened.
#' nrow(icebergr_collect(stale))
#' nrow(icebergr_collect(icebergr_reload(stale)))
#' @export
icebergr_reload <- function(tbl) {
  check_table(tbl)
  new_icebergr_table(rs_table_reload(tbl$ptr), tbl$catalog)
}

#' The properties of an Iceberg table
#'
#' Table properties are the free-form key-value settings Iceberg stores in table
#' metadata -- write defaults, compaction targets, engine-specific hints -- as
#' whichever engine created or last configured the table left them.
#'
#' @param tbl An `icebergr_table` from [icebergr_table()].
#'
#' @return A tibble of `name` and `value`, ordered by name. A table with no
#'   properties returns zero rows.
#'
#' @details
#' These are read-only here. Setting them is an `update_properties` transaction,
#' which is out of scope for this version; see [icebergr_spec_support()].
#'
#' Not to be confused with the `properties` argument of [icebergr_append()],
#' which records provenance in a single snapshot's summary rather than on the
#' table.
#'
#' @examples
#' tbl <- icebergr_example_table(rows = 10)
#' icebergr_properties(tbl)
#' @export
icebergr_properties <- function(tbl) {
  check_table(tbl)
  as_result_tbl(rs_table_properties(tbl$ptr))
}

#' The schema of an Iceberg table
#'
#' @param tbl An `icebergr_table` from [icebergr_table()].
#' @param snapshot_id Report the schema as it was at this snapshot rather than
#'   the current one. A character id from [icebergr_snapshots()].
#'
#' @return A tibble with one row per top-level field: `field_id`, `name`,
#'   `type` (the Iceberg type), `required` and `doc`.
#'
#' @details
#' Iceberg records a schema per snapshot, so a table whose columns were changed
#' by another engine has more than one. `snapshot_id` is how the earlier one is
#' read, and it is also what [icebergr_scan()] resolves `filter` and `select`
#' against when it is given a `snapshot_id` or an `as_of`: a column that has
#' since been renamed or dropped is still nameable as of the snapshot that had
#' it.
#'
#' @examples
#' tbl <- icebergr_example_table(rows = 10)
#' icebergr_schema(tbl)
#'
#' # The schema as of the first snapshot.
#' history <- icebergr_snapshots(tbl)
#' icebergr_schema(tbl, snapshot_id = history$snapshot_id[[1]])
#' @export
icebergr_schema <- function(tbl, snapshot_id = NULL) {
  check_table(tbl)
  raw <- rs_table_schema(tbl$ptr, as_snapshot_id(snapshot_id))
  # Rust hands the Iceberg type over as `field_type`, because `type` is a
  # keyword there and cannot name a `list!` argument. The column is `type`.
  tibble::tibble(
    field_id = raw$field_id,
    name = raw$name,
    type = raw$field_type,
    required = raw$required,
    doc = raw$doc
  )
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
#' # The example table is unpartitioned, so this has zero rows.
#' tbl <- icebergr_example_table(rows = 10)
#' icebergr_partitions(tbl)
#' @export
icebergr_partitions <- function(tbl) {
  check_table(tbl)
  as_result_tbl(rs_table_partitions(tbl$ptr))
}

#' The column names of a table, as of `snapshot_id`
#'
#' Snapshot-aware because a read is: `icebergr_scan()` resolves `filter` and
#' `select` against the schema of the snapshot it is going to read, not against
#' the current one. Resolving against the current schema refused a column the
#' snapshot did have, accepted one it did not, and read a filter naming a
#' since-renamed column as an ordinary local variable.
#' @noRd
table_columns <- function(tbl, snapshot_id = NULL) {
  rs_table_schema(tbl$ptr, snapshot_id)$name
}

#' @export
print.icebergr_table <- function(x, ...) {
  check_table(x)
  ident <- rs_table_identifier(x$ptr)
  schema <- icebergr_schema(x)
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
