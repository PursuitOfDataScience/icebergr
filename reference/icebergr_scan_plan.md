# Inspect the file plan for a scan

Reports which data files a scan would read, without reading them. This
is how pushdown is verified rather than assumed: a filtered scan should
plan fewer files, and fewer records, than an unfiltered one.

## Usage

``` r
icebergr_scan_plan(scan)
```

## Arguments

- scan:

  An `icebergr_scan` from
  [`icebergr_scan()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_scan.md).

## Value

A tibble with one row per planned file task: `data_file_path`,
`record_count`, `file_size_in_bytes`, `start` and `length`.

`record_count` is `NA` for a task covering part of a file, since a
partial read has no meaningful record count from the manifest.

## Examples

``` r
tbl <- icebergr_example_table(rows = 10)

# The example table has two data files, one per append.
all_files <- icebergr_scan_plan(icebergr_scan(tbl))
hot_files <- icebergr_scan_plan(icebergr_scan(tbl, filter = id > 1000))

nrow(hot_files) < nrow(all_files)
#> [1] TRUE
sum(hot_files$record_count) < sum(all_files$record_count)
#> [1] TRUE
```
