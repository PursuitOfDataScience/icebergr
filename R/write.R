# Append-only writes, plus the minimum needed to bring a table into existence.

#' Create a namespace
#'
#' @param catalog An `icebergr_catalog` from [icebergr_catalog()].
#' @param namespace The namespace to create. Accepts `"db"` or `c("a", "b")`.
#'
#' @return `catalog`, invisibly.
#'
#' @examples
#' warehouse <- tempfile("warehouse")
#' dir.create(warehouse)
#' catalog <- icebergr_catalog("memory", warehouse = warehouse)
#' icebergr_create_namespace(catalog, "db")
#' icebergr_list_namespaces(catalog)
#' @export
icebergr_create_namespace <- function(catalog, namespace) {
  check_catalog(catalog)
  levels <- as_namespace(namespace)

  # An Iceberg catalog will not create "a.b" until "a" exists, so creating a
  # nested namespace in one call fails with "No such namespace". Walk the
  # parents and fill in the missing ones. The leaf is still created
  # unconditionally, so asking for a namespace that already exists is an error
  # rather than a silent no-op.
  for (i in seq_len(length(levels) - 1L)) {
    parent <- levels[seq_len(i)]
    if (!rs_namespace_exists(catalog$ptr, parent)) {
      rs_create_namespace(catalog$ptr, parent)
    }
  }

  rs_create_namespace(catalog$ptr, levels)
  invisible(catalog)
}

#' Create an Iceberg table
#'
#' The table's schema is taken from `data`, so an existing data frame is enough
#' to define one. Iceberg field ids are assigned automatically, since a data
#' frame has no concept of them.
#'
#' @param catalog An `icebergr_catalog` from [icebergr_catalog()].
#' @param table A table identifier, `"namespace.table"`. The namespace must
#'   already exist; see [icebergr_create_namespace()].
#' @param data A data frame whose columns define the schema. No rows are written;
#'   only the column names and types are used. An Arrow schema is also accepted.
#' @param location Where to store the table. `NULL` lets the catalog decide,
#'   which is almost always what you want.
#'
#' @return An `icebergr_table` handle for the new, empty table.
#'
#' @details
#' The table is created unpartitioned. Partitioned table creation, like partition
#' evolution, is out of scope for this version; see [icebergr_spec_support()].
#'
#' @examples
#' warehouse <- tempfile("warehouse")
#' dir.create(warehouse)
#' catalog <- icebergr_catalog("memory", warehouse = warehouse)
#' icebergr_create_namespace(catalog, "db")
#'
#' tbl <- icebergr_create_table(
#'   catalog, "db.events",
#'   data.frame(id = integer(), amount = double(), label = character())
#' )
#' icebergr_schema(tbl)
#' @export
icebergr_create_table <- function(catalog, table, data, location = NULL) {
  check_catalog(catalog)
  check_string(location, "location")
  ident <- parse_identifier(table)

  if (!is.data.frame(data) && !inherits(data, "nanoarrow_schema")) {
    abort("`data` must be a data frame, or an Arrow schema.")
  }

  # The schema object has to outlive the call: Rust only borrows it.
  holder <- export_schema(data)
  ptr <- rs_create_table(
    catalog$ptr, ident$namespace, ident$name, holder$addr,
    # A caller-supplied location may be a Windows path or a URI. Only the former
    # has separators to normalise, and Iceberg wants them forward.
    if (is.null(location)) NULL else as_iceberg_location(location)
  )
  new_icebergr_table(ptr, catalog)
}

#' Register an existing table with a catalog
#'
#' Points a catalog at a table that already exists on disk, by giving it the
#' table's metadata file. This is how a warehouse directory becomes visible to an
#' in-process `memory` catalog, which keeps no persistent registry of its own.
#'
#' @param catalog An `icebergr_catalog` from [icebergr_catalog()].
#' @param table A table identifier, `"namespace.table"`, to register it under.
#' @param metadata_location Path to the table's `metadata.json`.
#'
#' @return An `icebergr_table` handle.
#'
#' @examples
#' # Build a table, then re-attach it from a second catalog, as you would in a
#' # new session: a memory catalog keeps no registry between sessions.
#' warehouse <- tempfile("warehouse")
#' dir.create(warehouse)
#' catalog <- icebergr_catalog("memory", warehouse = warehouse)
#' icebergr_create_namespace(catalog, "db")
#' tbl <- icebergr_create_table(catalog, "db.events", data.frame(id = 1:3))
#' tbl <- icebergr_append(tbl, data.frame(id = 1:3))
#'
#' # Iceberg writes one metadata file per commit; the newest is the current
#' # state of the table.
#' files <- list.files(warehouse,
#'   pattern = "metadata\\.json$", recursive = TRUE,
#'   full.names = TRUE
#' )
#' newest <- files[order(file.mtime(files))][length(files)]
#'
#' reopened <- icebergr_catalog("memory", warehouse = warehouse)
#' icebergr_create_namespace(reopened, "db")
#' again <- icebergr_register_table(reopened, "db.events", newest)
#' icebergr_collect(again)
#' @export
icebergr_register_table <- function(catalog, table, metadata_location) {
  check_catalog(catalog)
  check_string(metadata_location, "metadata_location", allow_null = FALSE)
  ident <- parse_identifier(table)

  if (!file.exists(metadata_location)) {
    abort(paste0(
      "No metadata file at ", encodeString(metadata_location, quote = "\""), "."
    ))
  }

  ptr <- rs_register_table(
    catalog$ptr, ident$namespace, ident$name,
    as_iceberg_location(normalizePath(metadata_location, mustWork = TRUE))
  )
  new_icebergr_table(ptr, catalog)
}

#' Append rows to an Iceberg table
#'
#' Writes `data` as one or more new Parquet data files and commits a new
#' snapshot. Nothing already in the table is rewritten or removed.
#'
#' @param tbl An `icebergr_table` from [icebergr_table()].
#' @param data A data frame, or anything [nanoarrow::as_nanoarrow_array_stream()]
#'   accepts, such as an Arrow Table.
#' @param compression Parquet compression: `"zstd"` (the default), `"snappy"`,
#'   `"gzip"`, `"lz4"` or `"uncompressed"`.
#' @param properties Optional named character vector recorded in the new
#'   snapshot's summary, for provenance. Do not put credentials here: snapshot
#'   summaries are stored in table metadata and are readable by anyone who can
#'   read the table.
#'
#' @return An updated `icebergr_table` handle that sees the new snapshot. The
#'   handle passed in is unchanged, so reassign it: `tbl <- icebergr_append(tbl, x)`.
#'
#' @details
#' Columns are matched to the table by *name*, not position, so column order in
#' `data` does not matter. Types are cast where they differ from the table's, and
#' a column the table does not have is an error rather than being dropped
#' silently.
#'
#' Appending zero rows is a no-op: it warns, and returns the table unchanged
#' rather than committing an empty snapshot that records that nothing happened.
#'
#' The table must be unpartitioned. An append to a partitioned table would have
#' to compute a partition value for every row, which this version does not do, so
#' it is refused before any data is written rather than failing at the commit with
#' files already left in the warehouse. Partitioned tables can still be read; see
#' [icebergr_partitions()] and [icebergr_spec_support()].
#'
#' A table registered with [icebergr_register_table()] must also have been
#' registered from a metadata file named the way Iceberg names them,
#' `<version>-<uuid>.metadata.json`, because the next one is derived from that
#' name. Every engine writes conforming names; a renamed or hand-made file reads
#' fine and is refused here, again before anything is written.
#'
#' This is an append. Row-level deletes, overwrites and MERGE are not supported;
#' see [icebergr_spec_support()].
#'
#' @examples
#' warehouse <- tempfile("warehouse")
#' dir.create(warehouse)
#' catalog <- icebergr_catalog("memory", warehouse = warehouse)
#' icebergr_create_namespace(catalog, "db")
#'
#' events <- data.frame(id = 1:3, amount = c(1.5, 2.5, 3.5))
#' tbl <- icebergr_create_table(catalog, "db.events", events)
#' tbl <- icebergr_append(tbl, events)
#' icebergr_collect(tbl)
#' @export
icebergr_append <- function(tbl,
                            data,
                            compression = c("zstd", "snappy", "gzip", "lz4", "uncompressed"),
                            properties = NULL) {
  check_table(tbl)
  compression <- match.arg(compression)

  keys <- character()
  values <- character()
  if (!is.null(properties)) {
    # anyNA(names()) as well as anyNA(values): nzchar(NA) is TRUE, so an NA name
    # slipped past the emptiness check and failed inside Rust with a bare
    # "Must not be NA".
    if (!is.character(properties) || is.null(names(properties)) ||
      any(!nzchar(names(properties))) || anyNA(names(properties)) ||
      anyNA(properties)) {
      abort("`properties` must be a fully named character vector without NAs.")
    }
    keys <- names(properties)
    values <- unname(properties)
  }

  before <- rs_table_current_snapshot(tbl$ptr)

  # The stream must outlive the call: Rust drains it during the append.
  holder <- export_stream(data)
  ptr <- rs_table_append(
    tbl = tbl$ptr,
    stream_addr = holder$addr,
    compression = compression,
    property_keys = keys,
    property_values = values
  )

  # Reported from what Rust actually did rather than from nrow(data), which only
  # exists for a data frame: an Arrow stream carrying no batches used to be a
  # silent no-op.
  if (identical(rs_table_current_snapshot(ptr), before)) {
    warn("`data` has no rows; the table is unchanged and no snapshot was committed.")
  }

  new_icebergr_table(ptr, tbl$catalog)
}
