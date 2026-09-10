# The properties of an Iceberg table

Table properties are the free-form key-value settings Iceberg stores in
table metadata – write defaults, compaction targets, engine-specific
hints – as whichever engine created or last configured the table left
them.

## Usage

``` r
icebergr_properties(tbl)
```

## Arguments

- tbl:

  An `icebergr_table` from
  [`icebergr_table()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_table.md).

## Value

A tibble of `name` and `value`, ordered by name. A table with no
properties returns zero rows.

## Details

These are read-only here. Setting them is an `update_properties`
transaction, which is out of scope for this version; see
[`icebergr_spec_support()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_spec_support.md).

Not to be confused with the `properties` argument of
[`icebergr_append()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_append.md),
which records provenance in a single snapshot's summary rather than on
the table.

## Examples

``` r
tbl <- icebergr_example_table(rows = 10)
icebergr_properties(tbl)
#> # A tibble: 0 × 2
#> # ℹ 2 variables: name <chr>, value <chr>
```
