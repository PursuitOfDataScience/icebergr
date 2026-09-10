# Append rows to an Iceberg table

Writes `data` as one or more new Parquet data files and commits a new
snapshot. Nothing already in the table is rewritten or removed.

## Usage

``` r
icebergr_append(
  tbl,
  data,
  compression = c("zstd", "snappy", "gzip", "lz4", "uncompressed"),
  properties = NULL
)
```

## Arguments

- tbl:

  An `icebergr_table` from
  [`icebergr_table()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_table.md).

- data:

  A data frame, or anything
  [`nanoarrow::as_nanoarrow_array_stream()`](https://arrow.apache.org/nanoarrow/latest/r/reference/as_nanoarrow_array_stream.html)
  accepts, such as an Arrow Table.

- compression:

  Parquet compression: `"zstd"` (the default), `"snappy"`, `"gzip"`,
  `"lz4"` or `"uncompressed"`.

- properties:

  Optional named character vector recorded in the new snapshot's
  summary, for provenance. Do not put credentials here: snapshot
  summaries are stored in table metadata and are readable by anyone who
  can read the table.

## Value

An updated `icebergr_table` handle that sees the new snapshot. The
handle passed in is unchanged, so reassign it:
`tbl <- icebergr_append(tbl, x)`.

## Details

Columns are matched to the table by *name*, not position, so column
order in `data` does not matter. Types are cast where they differ from
the table's, and a column the table does not have is an error rather
than being dropped silently.

Appending zero rows is a no-op: it warns, and returns the table
unchanged rather than committing an empty snapshot that records that
nothing happened.

The table must be unpartitioned. An append to a partitioned table would
have to compute a partition value for every row, which this version does
not do, so it is refused before any data is written rather than failing
at the commit with files already left in the warehouse. Partitioned
tables can still be read; see
[`icebergr_partitions()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_partitions.md)
and
[`icebergr_spec_support()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_spec_support.md).

A table registered with
[`icebergr_register_table()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_register_table.md)
must also have been registered from a metadata file named the way
Iceberg names them, `<version>-<uuid>.metadata.json`, because the next
one is derived from that name. Every engine writes conforming names; a
renamed or hand-made file reads fine and is refused here, again before
anything is written.

This is an append. Row-level deletes, overwrites and MERGE are not
supported; see
[`icebergr_spec_support()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_spec_support.md).

## Examples

``` r
warehouse <- tempfile("warehouse")
dir.create(warehouse)
catalog <- icebergr_catalog("memory", warehouse = warehouse)
icebergr_create_namespace(catalog, "db")

events <- data.frame(id = 1:3, amount = c(1.5, 2.5, 3.5))
tbl <- icebergr_create_table(catalog, "db.events", events)
tbl <- icebergr_append(tbl, events)
icebergr_collect(tbl)
#> # A tibble: 3 × 2
#>      id amount
#>   <int>  <dbl>
#> 1     1    1.5
#> 2     2    2.5
#> 3     3    3.5
```
