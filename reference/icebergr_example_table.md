# A small Iceberg table for offline examples and tests

Builds a real Iceberg table in a local warehouse directory: two appends,
so there is snapshot history to travel through and more than one data
file for a filter to prune. Everything is local; no catalog server,
network access or credentials are involved.

## Usage

``` r
icebergr_example_table(warehouse = tempfile("icebergr-warehouse"), rows = 500L)
```

## Arguments

- warehouse:

  Directory to build the warehouse in. The default is a fresh temporary
  directory, created if needed.

- rows:

  Rows per append. Two appends are made, so the table has twice this
  many rows.

## Value

An `icebergr_table` handle for `db.events`, with columns `id`, `event`,
`amount`, `day` (a `Date`) and `recorded_at` (a `POSIXct`).

## Details

This is generated on demand rather than shipped as a committed table
because Iceberg records absolute paths in its metadata and manifests: a
table built on one machine does not resolve on another.

## Examples

``` r
tbl <- icebergr_example_table(rows = 50)
tbl
#> <icebergr_table>
#>   table:    db.events
#>   location: /tmp/RtmpdAlRuI/icebergr-warehouse29286d383186/db/events
#>   format:   v2
#>   snapshot: 4869020072153332831
#>   columns:  5
#>     id <int>
#>     event <string>
#>     amount <double>
#>     day <date>
#>     recorded_at <timestamptz>

icebergr_collect(icebergr_scan(tbl, filter = id > 1000, select = c("id", "amount")))
#> # A tibble: 50 × 2
#>       id amount
#>    <int>  <dbl>
#>  1  1001   500 
#>  2  1002   510.
#>  3  1003   520.
#>  4  1004   531.
#>  5  1005   541.
#>  6  1006   551.
#>  7  1007   561.
#>  8  1008   571.
#>  9  1009   582.
#> 10  1010   592.
#> # ℹ 40 more rows

# Two snapshots, so the earlier state is still readable.
icebergr_snapshots(tbl)[, c("snapshot_id", "operation", "added_records")]
#> # A tibble: 2 × 3
#>   snapshot_id         operation added_records
#>   <chr>               <chr>             <dbl>
#> 1 3365355739611279202 append               50
#> 2 4869020072153332831 append               50
```
