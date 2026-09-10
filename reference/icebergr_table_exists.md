# Whether a table exists in a catalog

Asks the catalog directly, so an absent table is an answer rather than
an error to be caught.

## Usage

``` r
icebergr_table_exists(catalog, table)
```

## Arguments

- catalog:

  An `icebergr_catalog` from
  [`icebergr_catalog()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_catalog.md).

- table:

  A table identifier, `"namespace.table"`.

## Value

`TRUE` or `FALSE`.

## Details

A namespace that does not exist gives `FALSE` rather than an error,
since it cannot hold the table either way. Any other failure – an
unreachable catalog, a rejected credential – is still an error, because
reporting one of those as "no such table" would be a confident wrong
answer.

## Examples

``` r
warehouse <- tempfile("warehouse")
dir.create(warehouse)
catalog <- icebergr_catalog("memory", warehouse = warehouse)
icebergr_create_namespace(catalog, "db")

icebergr_table_exists(catalog, "db.events")
#> [1] FALSE
icebergr_create_table(catalog, "db.events", data.frame(id = integer()))
#> <icebergr_table>
#>   table:    db.events
#>   location: /tmp/RtmpmjDSA9/warehouse286951bd3c3f/db/events
#>   format:   v2
#>   snapshot: <none>
#>   columns:  1
#>     id <int>
icebergr_table_exists(catalog, "db.events")
#> [1] TRUE
```
