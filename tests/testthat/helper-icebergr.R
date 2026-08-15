# Test fixtures.
#
# Everything here is local and offline: an in-process `memory` catalog over a
# warehouse directory under tempdir(). No network, no catalog server, no
# credentials. That is both a CRAN requirement and the only way these tests could
# be reliable.
#
# The example table is built rather than loaded from inst/. An Iceberg table
# records absolute paths in its metadata and inside its Avro manifests, so a
# table committed to the package would carry the build machine's paths and stop
# resolving once installed elsewhere. See R/example.R.

# A fresh warehouse and catalog, cleaned up when the calling test finishes.
local_catalog <- function(env = parent.frame()) {
  warehouse <- withr::local_tempdir("warehouse", .local_envir = env)
  icebergr_catalog("memory", warehouse = warehouse)
}

# A catalog with an empty namespace ready to hold tables.
local_namespace <- function(namespace = "db", env = parent.frame()) {
  catalog <- local_catalog(env = env)
  icebergr_create_namespace(catalog, namespace)
  catalog
}

# Create a table from `data` and append it, returning the handle.
seed_table <- function(catalog, table, data) {
  tbl <- icebergr_create_table(catalog, table, data)
  icebergr_append(tbl, data)
}

# The multi-snapshot example table. Kept small: these tests care about structure,
# not volume.
local_fixture_table <- function(rows = 50L, env = parent.frame()) {
  warehouse <- withr::local_tempdir("fixture", .local_envir = env)
  icebergr_example_table(warehouse = warehouse, rows = rows)
}

# Rewrite a warehouse's newest table metadata as though the table had been rolled
# back to `to_snapshot`, and hand back a handle on the result.
#
# Built by hand because icebergr cannot roll a table back itself, and a rollback
# is the one shape where Iceberg's snapshot *log* and snapshot *list* give
# different answers: the rollback appends a log entry pointing at the earlier
# snapshot, while the snapshot it abandoned stays in the list carrying its own,
# later, timestamp. `as_of` has to follow the log. Only the three fields a
# rollback touches are rewritten; the field names are the Iceberg spec's, not
# iceberg-rust's.
rolled_back_table <- function(warehouse, table, to_snapshot) {
  files <- list.files(warehouse,
    pattern = "metadata\\.json$",
    recursive = TRUE, full.names = TRUE
  )
  newest <- files[order(file.mtime(files))][length(files)]
  json <- paste(readLines(newest, warn = FALSE), collapse = "")

  updated <- as.numeric(sub('.*"last-updated-ms"[ ]*:[ ]*([0-9]+).*', "\\1", json))
  rolled_at <- sprintf("%.0f", updated + 1000)

  json <- sub(
    '("snapshot-log"[ ]*:[ ]*\\[[^]]*)\\]',
    paste0(
      '\\1,{"snapshot-id":', to_snapshot,
      ',"timestamp-ms":', rolled_at, "}]"
    ),
    json
  )
  json <- sub(
    '"current-snapshot-id"[ ]*:[ ]*-?[0-9]+',
    paste0('"current-snapshot-id":', to_snapshot), json
  )
  # The main branch ref moves with it. iceberg-rust refuses metadata whose
  # current-snapshot-id and main ref disagree, which is the right thing to refuse:
  # they are two records of the same fact.
  json <- sub(
    '("refs"[ ]*:[ ]*\\{[ ]*"main"[ ]*:[ ]*\\{[^}]*"snapshot-id"[ ]*:[ ]*)-?[0-9]+',
    paste0("\\1", to_snapshot), json
  )
  json <- sub(
    '"last-updated-ms"[ ]*:[ ]*[0-9]+',
    paste0('"last-updated-ms":', rolled_at), json
  )

  path <- file.path(dirname(newest), "99999-rollback.metadata.json")
  writeLines(json, path)

  reopened <- icebergr_catalog("memory", warehouse = warehouse)
  icebergr_create_namespace(reopened, sub("[.][^.]*$", "", table))
  list(
    table = icebergr_register_table(reopened, table, path),
    rolled_at = as.POSIXct(as.numeric(rolled_at) / 1000, origin = "1970-01-01", tz = "UTC")
  )
}
