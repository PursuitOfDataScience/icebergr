# Snapshot history of an Iceberg table

Snapshot history of an Iceberg table

## Usage

``` r
icebergr_snapshots(tbl)
```

## Arguments

- tbl:

  An `icebergr_table` from
  [`icebergr_table()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_table.md).

## Value

A tibble of snapshots, oldest first, with columns:

- `snapshot_id`:

  Character. See the note on ids below.

- `parent_snapshot_id`:

  Character, `NA` for the first snapshot.

- `sequence_number`:

  Numeric.

- `timestamp`:

  `POSIXct` in UTC, when the snapshot was committed.

- `operation`:

  `"append"`, `"overwrite"`, `"replace"` or `"delete"`.

- `schema_id`:

  Integer, the schema in force for that snapshot.

- `added_records`, `total_records`:

  Numeric, from the snapshot summary, `NA` when the writer did not
  record them.

- `summary`:

  The full snapshot summary as a JSON string.

- `manifest_list`:

  Path to the snapshot's manifest list.

## Snapshot ids are character

Iceberg assigns snapshot ids as random 64-bit integers, and R's numeric
type holds only 53 bits of integer precision. A large id passed through
a double would come back subtly altered and then silently select the
wrong snapshot, so ids are character throughout, and
[`icebergr_scan()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_scan.md)
accepts them as such.

## Every snapshot, not only the current line

This is the table's snapshot *list*: every snapshot the metadata still
carries, ordered by commit time. That is not always the same as the
states the table passed through. A rollback leaves the snapshot it
abandoned in the list, and a snapshot committed to another branch
appears here too, in both cases with a timestamp at which it was never
the table's current state. Reading with `icebergr_scan(as_of = )`
follows Iceberg's snapshot log instead, so it is not misled by either;
any id listed here can still be read directly with
`icebergr_scan(snapshot_id = )`.

## Examples

``` r
# Two appends, so there is history to travel through.
tbl <- icebergr_example_table(rows = 10)

history <- icebergr_snapshots(tbl)
history[, c("snapshot_id", "operation", "added_records", "total_records")]
#> # A tibble: 2 × 4
#>   snapshot_id         operation added_records total_records
#>   <chr>               <chr>             <dbl>         <dbl>
#> 1 2586361041378692999 append               10            10
#> 2 2430817359429219023 append               10            20

# Read the table as it was at its first snapshot.
icebergr_collect(icebergr_scan(tbl, snapshot_id = history$snapshot_id[[1]]))
#> # A tibble: 10 × 5
#>       id event    amount day        recorded_at        
#>    <int> <chr>     <dbl> <date>     <dttm>             
#>  1     1 click       0.5 2024-01-01 2024-01-01 00:00:00
#>  2     2 view       28.2 2024-01-02 2024-01-01 01:00:00
#>  3     3 purchase   55.9 2024-01-03 2024-01-01 02:00:00
#>  4     4 scroll     83.7 2024-01-04 2024-01-01 03:00:00
#>  5     5 click     111.  2024-01-05 2024-01-01 04:00:00
#>  6     6 view      139.  2024-01-06 2024-01-01 05:00:00
#>  7     7 purchase  167.  2024-01-07 2024-01-01 06:00:00
#>  8     8 scroll    195.  2024-01-08 2024-01-01 07:00:00
#>  9     9 click     222.  2024-01-09 2024-01-01 08:00:00
#> 10    10 view      250   2024-01-10 2024-01-01 09:00:00
```
