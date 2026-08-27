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

# A metadata file name Iceberg can derive the *next* one from.
#
# Iceberg names these <version>-<uuid>.metadata.json and parses the current name
# to build the successor, so a hand-written file needs a real uuid in it or the
# table reads fine and fails its first append. Every engine produces conforming
# names, so the helpers below use one too rather than exercising a shape no real
# warehouse contains.
metadata_file_name <- function(version = 99999L) {
  hex <- paste(sample(c(0:9, letters[1:6]), 32L, replace = TRUE), collapse = "")
  uuid <- paste(
    substr(hex, 1, 8), substr(hex, 9, 12), substr(hex, 13, 16),
    substr(hex, 17, 20), substr(hex, 21, 32),
    sep = "-"
  )
  sprintf("%05d-%s.metadata.json", version, uuid)
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

  path <- file.path(dirname(newest), metadata_file_name())
  writeLines(json, path)

  reopened <- icebergr_catalog("memory", warehouse = warehouse)
  icebergr_create_namespace(reopened, sub("[.][^.]*$", "", table))
  list(
    table = icebergr_register_table(reopened, table, path),
    rolled_at = as.POSIXct(as.numeric(rolled_at) / 1000, origin = "1970-01-01", tz = "UTC")
  )
}

# Give a freshly created, empty table a partition spec, and hand back a handle.
#
# icebergr cannot create a partitioned table -- that is out of scope, and stated
# as such -- but it is documented as *reporting* one, and a table registered from
# another engine is exactly how a user would meet one. So the spec is written by
# hand. Only ever applied to a table with no data: rewriting the spec of a table
# that already holds files would contradict the partition tuples in its manifests.
#
# `fields` is a list of list(source_id =, field_id =, transform =, name =).
partitioned_table <- function(warehouse, table, fields) {
  files <- list.files(warehouse,
    pattern = "metadata\\.json$",
    recursive = TRUE, full.names = TRUE
  )
  newest <- files[order(file.mtime(files))][length(files)]
  json <- paste(readLines(newest, warn = FALSE), collapse = "")

  entries <- vapply(
    fields,
    function(f) {
      sprintf(
        '{"source-id":%d,"field-id":%d,"transform":"%s","name":"%s"}',
        f$source_id, f$field_id, f$transform, f$name
      )
    },
    character(1)
  )
  spec <- paste0(
    '"partition-specs":[{"spec-id":0,"fields":[',
    paste(entries, collapse = ","), "]}]"
  )
  spec <- sub('"$', "", spec)

  replaced <- sub('"partition-specs":\\[[^]]*\\]\\}\\]', spec, json)
  # A silent no-op here would leave the table unpartitioned and the test would
  # then assert nothing at all.
  stopifnot(!identical(replaced, json))
  json <- sub(
    '"last-partition-id":[0-9]+',
    paste0('"last-partition-id":', max(vapply(fields, function(f) f$field_id, numeric(1)))),
    replaced
  )

  path <- file.path(dirname(newest), metadata_file_name())
  writeLines(json, path)

  reopened <- icebergr_catalog("memory", warehouse = warehouse)
  icebergr_create_namespace(reopened, sub("[.][^.]*$", "", table))
  icebergr_register_table(reopened, table, path)
}

# Give a table a set of table properties, and hand back a handle.
#
# icebergr cannot write these -- that needs an update_properties transaction,
# which is out of scope and documented as such -- so a table that has any can
# only be met by registering one whose metadata already carries them, the way
# another engine would leave it. Written by hand for the same reason
# partitioned_table() is, and worth having because otherwise every table these
# tests can build has an empty property map: iceberg-rust's TableCreation starts
# with one and icebergr never sets it.
#
# The key is *inserted* rather than rewritten. iceberg-rust omits "properties"
# from the JSON entirely when the map is empty, so there is nothing to rewrite;
# inserting straight after the opening brace is unambiguous, and the order of
# keys in a JSON object carries no meaning.
with_properties <- function(warehouse, table, properties) {
  stopifnot(is.character(properties), !is.null(names(properties)))
  files <- list.files(warehouse,
    pattern = "metadata\\.json$",
    recursive = TRUE, full.names = TRUE
  )
  newest <- files[order(file.mtime(files))][length(files)]
  json <- paste(readLines(newest, warn = FALSE), collapse = "")

  entries <- paste0(
    '"', names(properties), '":"', unname(properties), '"',
    collapse = ","
  )
  replaced <- sub("^\\{", paste0('{"properties":{', entries, "},"), json)
  # A silent no-op would leave the table with no properties and the test would
  # then assert nothing, which is the very thing this helper exists to fix.
  stopifnot(!identical(replaced, json))

  path <- file.path(dirname(newest), metadata_file_name())
  writeLines(replaced, path)

  reopened <- icebergr_catalog("memory", warehouse = warehouse)
  icebergr_create_namespace(reopened, sub("[.][^.]*$", "", table))
  icebergr_register_table(reopened, table, path)
}
