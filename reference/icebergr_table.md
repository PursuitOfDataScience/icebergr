# Open an Iceberg table

Open an Iceberg table

## Usage

``` r
icebergr_table(catalog, table)
```

## Arguments

- catalog:

  An `icebergr_catalog` from
  [`icebergr_catalog()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_catalog.md).

- table:

  A table identifier, `"namespace.table"`. Nested namespaces are written
  `"a.b.table"`.

## Value

An `icebergr_table` handle.

## Details

The handle is a snapshot of the table's metadata at the moment it was
opened. Appending with
[`icebergr_append()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_append.md)
returns an updated handle rather than mutating this one, so a handle
always reads a consistent view.

## Examples

``` r
# A local warehouse, so this runs offline.
warehouse <- tempfile("warehouse")
dir.create(warehouse)
catalog <- icebergr_catalog("memory", warehouse = warehouse)
icebergr_create_namespace(catalog, "db")
icebergr_create_table(catalog, "db.events", data.frame(id = integer()))
#> <icebergr_table>
#>   table:    db.events
#>   location: /tmp/RtmpVsEjfo/warehouse286f7af21f44/db/events
#>   format:   v2
#>   snapshot: <none>
#>   columns:  1
#>     id <int>

tbl <- icebergr_table(catalog, "db.events")
icebergr_schema(tbl)
#> # A tibble: 1 × 5
#>   field_id name  type  required doc  
#>      <int> <chr> <chr> <lgl>    <chr>
#> 1        1 id    int   FALSE    NA   

if (FALSE) { # \dontrun{
# The same call against a REST catalog, which needs a server.
catalog <- icebergr_catalog("rest", uri = "https://catalog.example.com")
tbl <- icebergr_table(catalog, "db.events")
} # }
```
