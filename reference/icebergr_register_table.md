# Register an existing table with a catalog

Points a catalog at a table that already exists on disk, by giving it
the table's metadata file. This is how a warehouse directory becomes
visible to an in-process `memory` catalog, which keeps no persistent
registry of its own.

## Usage

``` r
icebergr_register_table(catalog, table, metadata_location, confine = TRUE)
```

## Arguments

- catalog:

  An `icebergr_catalog` from
  [`icebergr_catalog()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_catalog.md).

- table:

  A table identifier, `"namespace.table"`, to register it under.

- metadata_location:

  Path to the table's `metadata.json`.

- confine:

  Whether to require `metadata_location` to sit inside the catalog's own
  `warehouse`. `TRUE` (the default) refuses anything outside it; `FALSE`
  allows any path. Ignored when the catalog has no warehouse location to
  confine against, such as a REST catalog identified by name.

## Value

An `icebergr_table` handle.

## Registering a metadata file you did not write

A metadata file names its table's `location`, its manifest list and
every data file, all as absolute paths, and registering it makes this
package read them. Those paths are not constrained by where the metadata
file itself sits, so a file from a shared drive or an issue attachment
can point anywhere on disk – and, with the `s3` feature compiled in, at
an `s3://` or `https://` location, which turns opening a nominally
offline `memory`-catalog table into an outbound request to a host of its
author's choosing.

`confine = TRUE` is the guard: the metadata file has to be inside the
catalog's warehouse, which is the directory you nominated. It does not
vet the paths *within* the file, so treat `confine = FALSE` as
equivalent to running the file's author's code against your filesystem.

## Examples

``` r
# Build a table, then re-attach it from a second catalog, as you would in a
# new session: a memory catalog keeps no registry between sessions.
warehouse <- tempfile("warehouse")
dir.create(warehouse)
catalog <- icebergr_catalog("memory", warehouse = warehouse)
icebergr_create_namespace(catalog, "db")
tbl <- icebergr_create_table(catalog, "db.events", data.frame(id = 1:3))
tbl <- icebergr_append(tbl, data.frame(id = 1:3))

# Iceberg writes one metadata file per commit; the newest is the current
# state of the table.
files <- list.files(warehouse,
  pattern = "metadata\\.json$", recursive = TRUE,
  full.names = TRUE
)
newest <- files[order(file.mtime(files))][length(files)]

reopened <- icebergr_catalog("memory", warehouse = warehouse)
icebergr_create_namespace(reopened, "db")
again <- icebergr_register_table(reopened, "db.events", newest)
icebergr_collect(again)
#> # A tibble: 3 × 1
#>      id
#>   <int>
#> 1     1
#> 2     2
#> 3     3
```
