# Scan an Iceberg table

Describes a read without performing it. Pass the result to
[`icebergr_collect()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_collect.md)
or [`as.data.frame()`](https://rdrr.io/r/base/as.data.frame.html) to
materialise it.

## Usage

``` r
icebergr_scan(
  tbl,
  filter = NULL,
  select = NULL,
  limit = NULL,
  snapshot_id = NULL,
  as_of = NULL,
  batch_size = NULL,
  case_sensitive = TRUE
)
```

## Arguments

- tbl:

  An `icebergr_table` from
  [`icebergr_table()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_table.md).

- filter:

  An unquoted R expression, pushed down to Iceberg. See *Pushdown* below
  for what can be expressed.

- select:

  Character vector of columns to read. `NULL` reads all of them.

- limit:

  Maximum number of rows to return, or `NULL` for no limit. See
  *Pushdown* for an important caveat.

- snapshot_id:

  Read this snapshot instead of the current one. A character id from
  [`icebergr_snapshots()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_snapshots.md).

- as_of:

  Read the table as it was at this time, a `POSIXct` or `Date`. Resolved
  against the table's snapshot log to the snapshot that was current at
  that moment – so a snapshot a rollback abandoned, or one that only
  ever existed on another branch, is not selected even though it carries
  a matching timestamp. Cannot be combined with `snapshot_id`.

- batch_size:

  Rows per Arrow batch, or `NULL` for the default. Affects memory use,
  not results.

- case_sensitive:

  Whether column names in `filter` and `select` are matched
  case-sensitively. When `FALSE`, each name is resolved to the table's
  own spelling before the scan is planned, so `select = "ID"` reads the
  column the table calls `id`.

  An exact match always wins. Iceberg column names are case-sensitive,
  so a table may hold both `id` and `ID`; asking for `ID` reads `ID`,
  not whichever the two happen to be ordered. A name that matches no
  column exactly and more than one case-insensitively is ambiguous, and
  is an error rather than a silent choice between them.

## Value

An `icebergr_scan` object.

## Pushdown

`filter` and `select` are pushed down into scan planning, which is the
whole performance argument for Iceberg over reading raw Parquet:
manifests carry per-file statistics, so entire files and row groups are
skipped before any bytes are read. Inspect the effect with
[`icebergr_scan_plan()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_scan_plan.md).

`limit` is **not** pushed down: `iceberg-rust` has no row limit in its
scan API, so the same files are planned and rows are counted as batches
arrive. It bounds how much is decoded and converted, not how much is
planned.

Filters may use `==`, `!=`, `<`, `<=`, `>`, `>=`, `&`, `|`, `!`, `%in%`,
[`is.na()`](https://rdrr.io/r/base/NA.html),
[`is.nan()`](https://rdrr.io/r/base/is.finite.html) and
[`startsWith()`](https://rdrr.io/r/base/startsWith.html). A bare name is
read as a column when the table has a column of that name, and otherwise
evaluated in the calling environment, so `filter = year == target` works
with a local `target`. Anything more elaborate should be applied in R
after collecting.

[`startsWith()`](https://rdrr.io/r/base/startsWith.html) is pushed down
only against a `string` column, since Iceberg defines a prefix
comparison for no other type.

A filter on a `decimal` column is pushed down, but with `iceberg-rust`'s
row-level selection turned off for that scan: in 0.10.0 that stage drops
every row of an ordering comparison against a decimal, so `price > 2.25`
returned nothing at all. File and row-group pruning still apply, so such
a scan is a little less selective and still correct.

## Column names and time travel

Iceberg records a schema per snapshot, so `filter` and `select` are
resolved against the schema of the snapshot actually being read – the
one named by `snapshot_id` or `as_of`, and otherwise the current one. A
column another engine has since renamed or dropped is therefore still
nameable as of a snapshot that had it, and one added afterwards is
refused for a snapshot that did not.
[`icebergr_schema()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_schema.md)
takes the same `snapshot_id` and reports what those columns are.

## Examples

``` r
tbl <- icebergr_example_table(rows = 10)

# Projection and predicate pushdown
scan <- icebergr_scan(tbl, filter = id > 1000 & amount > 900, select = c("id", "amount"))
scan
#> <icebergr_scan>
#>   table:    db.events
#>   select:   id, amount
#>   filter:   id > 1000 & amount > 900 (pushed down)
#>   Use icebergr_collect() to read it.
icebergr_collect(scan)
#> # A tibble: 2 × 2
#>      id amount
#>   <int>  <dbl>
#> 1  1009   944.
#> 2  1010  1000 

# A local variable is usable in a filter: a bare name is read as a column
# only when the table has one of that name.
cutoff <- 1005
icebergr_collect(icebergr_scan(tbl, filter = id > cutoff, select = "id"))
#> # A tibble: 5 × 1
#>      id
#>   <int>
#> 1  1006
#> 2  1007
#> 3  1008
#> 4  1009
#> 5  1010

# Time travel, to the state before the second append
history <- icebergr_snapshots(tbl)
nrow(icebergr_collect(icebergr_scan(tbl, snapshot_id = history$snapshot_id[[1]])))
#> [1] 10
nrow(icebergr_collect(icebergr_scan(tbl, as_of = history$timestamp[[1]])))
#> [1] 10
```
