# Materialise a scan or a table

Materialise a scan or a table

## Usage

``` r
icebergr_collect(x, ...)

# S3 method for class 'icebergr_scan'
icebergr_collect(x, ...)

# S3 method for class 'icebergr_table'
icebergr_collect(x, ...)

# S3 method for class 'icebergr_scan'
as.data.frame(x, row.names = NULL, optional = FALSE, ...)

# S3 method for class 'icebergr_table'
as.data.frame(x, row.names = NULL, optional = FALSE, ...)
```

## Arguments

- x:

  An `icebergr_scan` from
  [`icebergr_scan()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_scan.md),
  or an `icebergr_table` (equivalent to scanning all of it).

- ...:

  Unused, for S3 consistency.

- row.names:

  Unused, for consistency with
  [`base::as.data.frame()`](https://rdrr.io/r/base/as.data.frame.html).

- optional:

  Unused, for consistency with
  [`base::as.data.frame()`](https://rdrr.io/r/base/as.data.frame.html).

## Value

A tibble.

## Details

Data crosses from Rust into R over the Arrow C stream interface, so
batches are handed over by pointer rather than serialised.

If the dplyr package is installed,
[`dplyr::collect()`](https://dplyr.tidyverse.org/reference/compute.html)
also works on these objects.

## Examples

``` r
tbl <- icebergr_example_table(rows = 10)

# A scan, materialised
icebergr_collect(icebergr_scan(tbl, filter = id > 1000, select = c("id", "amount")))
#> # A tibble: 10 × 2
#>       id amount
#>    <int>  <dbl>
#>  1  1001   500 
#>  2  1002   556.
#>  3  1003   611.
#>  4  1004   667.
#>  5  1005   722.
#>  6  1006   778.
#>  7  1007   833.
#>  8  1008   889.
#>  9  1009   944.
#> 10  1010  1000 

# A whole table, materialised
icebergr_collect(tbl)
#> # A tibble: 20 × 5
#>       id event    amount day        recorded_at        
#>    <int> <chr>     <dbl> <date>     <dttm>             
#>  1  1001 purchase  500   2024-06-01 2024-06-01 00:00:00
#>  2  1002 refund    556.  2024-06-02 2024-06-01 01:00:00
#>  3  1003 purchase  611.  2024-06-03 2024-06-01 02:00:00
#>  4  1004 refund    667.  2024-06-04 2024-06-01 03:00:00
#>  5  1005 purchase  722.  2024-06-05 2024-06-01 04:00:00
#>  6  1006 refund    778.  2024-06-06 2024-06-01 05:00:00
#>  7  1007 purchase  833.  2024-06-07 2024-06-01 06:00:00
#>  8  1008 refund    889.  2024-06-08 2024-06-01 07:00:00
#>  9  1009 purchase  944.  2024-06-09 2024-06-01 08:00:00
#> 10  1010 refund   1000   2024-06-10 2024-06-01 09:00:00
#> 11     1 click       0.5 2024-01-01 2024-01-01 00:00:00
#> 12     2 view       28.2 2024-01-02 2024-01-01 01:00:00
#> 13     3 purchase   55.9 2024-01-03 2024-01-01 02:00:00
#> 14     4 scroll     83.7 2024-01-04 2024-01-01 03:00:00
#> 15     5 click     111.  2024-01-05 2024-01-01 04:00:00
#> 16     6 view      139.  2024-01-06 2024-01-01 05:00:00
#> 17     7 purchase  167.  2024-01-07 2024-01-01 06:00:00
#> 18     8 scroll    195.  2024-01-08 2024-01-01 07:00:00
#> 19     9 click     222.  2024-01-09 2024-01-01 08:00:00
#> 20    10 view      250   2024-01-10 2024-01-01 09:00:00
```
