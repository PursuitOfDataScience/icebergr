# The partition specification of an Iceberg table

The partition specification of an Iceberg table

## Usage

``` r
icebergr_partitions(tbl)
```

## Arguments

- tbl:

  An `icebergr_table` from
  [`icebergr_table()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_table.md).

## Value

A tibble with one row per partition field: `spec_id`, `field_id`,
`name`, `transform`, `source_id` and `source_name`. An unpartitioned
table returns zero rows.

## Details

Only the table's *default* (current) partition spec is reported. Reading
historical specs would be part of partition evolution, which is out of
scope for this version.

## Examples

``` r
# The example table is unpartitioned, so this has zero rows.
tbl <- icebergr_example_table(rows = 10)
icebergr_partitions(tbl)
#> # A tibble: 0 × 6
#> # ℹ 6 variables: spec_id <int>, field_id <int>, name <chr>, transform <chr>,
#> #   source_id <int>, source_name <chr>
```
