# The schema of an Iceberg table

The schema of an Iceberg table

## Usage

``` r
icebergr_schema(tbl, snapshot_id = NULL)
```

## Arguments

- tbl:

  An `icebergr_table` from
  [`icebergr_table()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_table.md).

- snapshot_id:

  Report the schema as it was at this snapshot rather than the current
  one. A character id from
  [`icebergr_snapshots()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_snapshots.md).

## Value

A tibble with one row per top-level field: `field_id`, `name`, `type`
(the Iceberg type), `required` and `doc`.

## Details

Iceberg records a schema per snapshot, so a table whose columns were
changed by another engine has more than one. `snapshot_id` is how the
earlier one is read, and it is also what
[`icebergr_scan()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_scan.md)
resolves `filter` and `select` against when it is given a `snapshot_id`
or an `as_of`: a column that has since been renamed or dropped is still
nameable as of the snapshot that had it.

## Examples

``` r
tbl <- icebergr_example_table(rows = 10)
icebergr_schema(tbl)
#> # A tibble: 5 × 5
#>   field_id name        type        required doc  
#>      <int> <chr>       <chr>       <lgl>    <chr>
#> 1        1 id          int         FALSE    NA   
#> 2        2 event       string      FALSE    NA   
#> 3        3 amount      double      FALSE    NA   
#> 4        4 day         date        FALSE    NA   
#> 5        5 recorded_at timestamptz FALSE    NA   

# The schema as of the first snapshot.
history <- icebergr_snapshots(tbl)
icebergr_schema(tbl, snapshot_id = history$snapshot_id[[1]])
#> # A tibble: 5 × 5
#>   field_id name        type        required doc  
#>      <int> <chr>       <chr>       <lgl>    <chr>
#> 1        1 id          int         FALSE    NA   
#> 2        2 event       string      FALSE    NA   
#> 3        3 amount      double      FALSE    NA   
#> 4        4 day         date        FALSE    NA   
#> 5        5 recorded_at timestamptz FALSE    NA   
```
