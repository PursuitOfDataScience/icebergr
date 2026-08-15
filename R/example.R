# The offline example table.
#
# Why this is generated rather than committed as bytes: an Iceberg table records
# absolute paths, both in its metadata JSON and inside its Avro manifests. A
# table committed to the package would carry the paths of the machine that built
# it, and would stop resolving the moment it was installed anywhere else.
# Rewriting them is not practical either, since the manifests are Avro.
#
# Building the table on demand is therefore the only way to get a *real* Iceberg
# table that works offline, from any library location, with no catalog server and
# no credentials.

example_schema <- function() {
  data.frame(
    id = integer(),
    event = character(),
    amount = double(),
    day = as.Date(character()),
    recorded_at = as.POSIXct(character(), tz = "UTC"),
    stringsAsFactors = FALSE
  )
}

example_batches <- function(n = 500L) {
  first <- data.frame(
    id = seq_len(n),
    event = rep(c("click", "view", "purchase", "scroll"), length.out = n),
    amount = round(seq(0.5, 250, length.out = n), 2),
    day = as.Date("2024-01-01") + (seq_len(n) - 1L) %% 90L,
    recorded_at = as.POSIXct("2024-01-01 00:00:00", tz = "UTC") +
      (seq_len(n) - 1L) * 3600,
    stringsAsFactors = FALSE
  )

  # A disjoint, much higher id range, so that per-file statistics in the manifest
  # can eliminate this file outright for a filter such as `id > 1000`. Without
  # that separation there would be nothing for pushdown to prune.
  second <- data.frame(
    id = 1000L + seq_len(n),
    event = rep(c("purchase", "refund"), length.out = n),
    amount = round(seq(500, 1000, length.out = n), 2),
    day = as.Date("2024-06-01") + (seq_len(n) - 1L) %% 60L,
    recorded_at = as.POSIXct("2024-06-01 00:00:00", tz = "UTC") +
      (seq_len(n) - 1L) * 3600,
    stringsAsFactors = FALSE
  )

  list(first, second)
}

#' A small Iceberg table for offline examples and tests
#'
#' Builds a real Iceberg table in a local warehouse directory: two appends, so
#' there is snapshot history to travel through and more than one data file for a
#' filter to prune. Everything is local; no catalog server, network access or
#' credentials are involved.
#'
#' @param warehouse Directory to build the warehouse in. The default is a fresh
#'   temporary directory, created if needed.
#' @param rows Rows per append. Two appends are made, so the table has twice
#'   this many rows.
#'
#' @return An `icebergr_table` handle for `db.events`, with columns `id`,
#'   `event`, `amount`, `day` (a `Date`) and `recorded_at` (a `POSIXct`).
#'
#' @details
#' This is generated on demand rather than shipped as a committed table because
#' Iceberg records absolute paths in its metadata and manifests: a table built on
#' one machine does not resolve on another.
#'
#' @examples
#' tbl <- icebergr_example_table(rows = 50)
#' tbl
#'
#' icebergr_collect(icebergr_scan(tbl, filter = id > 1000, select = c("id", "amount")))
#'
#' # Two snapshots, so the earlier state is still readable.
#' icebergr_snapshots(tbl)[, c("snapshot_id", "operation", "added_records")]
#' @export
icebergr_example_table <- function(warehouse = tempfile("icebergr-warehouse"),
                                   rows = 500L) {
  check_string(warehouse, "warehouse", allow_null = FALSE)
  # `max` matters: `rows` is narrowed with as.integer() below to build the
  # batches, and without a bound anything past .Machine$integer.max became NA
  # there -- surfacing as "NAs introduced by coercion" followed by a seq_len()
  # error, neither of which names the argument at fault.
  check_count(rows, "rows", max = .Machine$integer.max)
  if (is.null(rows) || rows < 1) {
    abort("`rows` must be at least 1.")
  }

  if (!dir.exists(warehouse)) {
    if (!dir.create(warehouse, recursive = TRUE, showWarnings = FALSE)) {
      abort(paste0(
        "Could not create the warehouse directory ",
        encodeString(warehouse, quote = "\""), "."
      ))
    }
  }

  catalog <- icebergr_catalog("memory", warehouse = warehouse)
  icebergr_create_namespace(catalog, "db")

  batches <- example_batches(as.integer(rows))
  tbl <- icebergr_create_table(catalog, "db.events", example_schema())
  for (batch in batches) {
    tbl <- icebergr_append(tbl, batch, compression = "zstd")
  }
  tbl
}
