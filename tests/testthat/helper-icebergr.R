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
