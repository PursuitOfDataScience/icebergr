# Register an existing table with a catalog

Points a catalog at a table that already exists on disk, by giving it
the table's metadata file. This is how a warehouse directory becomes
visible to an in-process `memory` catalog, which keeps no persistent
registry of its own.

## Usage

``` r
icebergr_register_table(catalog, table, metadata_location)
```

## Arguments

- catalog:

  An `icebergr_catalog` from
  [`icebergr_catalog()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_catalog.md).

- table:

  A table identifier, `"namespace.table"`, to register it under.

- metadata_location:

  Path to the table's `metadata.json`.

## Value

An `icebergr_table` handle.

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
