# Time Travel: Snapshots, Timestamps and Rollbacks

Every Iceberg commit leaves the previous state of the table intact and
readable (The Apache Software Foundation 2026). Nothing is overwritten,
so a snapshot from before a bad load is still there — and reading it
needs no backup, no restore and no cooperation from whoever wrote it.

``` r

tbl <- icebergr_example_table(rows = 200)
```

### The snapshot log

``` r

history <- icebergr_snapshots(tbl)
history[, c(
  "snapshot_id", "parent_snapshot_id", "operation", "added_records",
  "total_records"
)]
#> # A tibble: 2 × 5
#>   snapshot_id         parent_snapshot_id  operation added_records total_records
#>   <chr>               <chr>               <chr>             <dbl>         <dbl>
#> 1 2453586216984749310 NA                  append              200           200
#> 2 2476317578153691360 2453586216984749310 append              200           400
```

The example table was built with two appends, so there are two snapshots
and the second’s parent is the first. `total_records` is cumulative;
`added_records` is what that commit contributed.

**Snapshot ids are `character`, not numeric.** Iceberg assigns them as
random 64-bit integers and an R double carries only 53 bits of mantissa,
so a numeric round trip would silently select a *different, existing*
snapshot rather than fail. This is the one type decision in the package
that exists purely to prevent a wrong answer:

``` r

class(history$snapshot_id)
#> [1] "character"
```

### Reading a snapshot by id

``` r

first <- history$snapshot_id[[1]]

nrow(icebergr_collect(icebergr_scan(tbl, snapshot_id = first)))
#> [1] 200
nrow(icebergr_collect(icebergr_scan(tbl)))
#> [1] 400
```

The first snapshot holds one append; the current table holds both.
Pushdown works against a historical snapshot exactly as it does against
the current one, because the manifests of that snapshot are still on
disk with their statistics intact:

``` r

nrow(icebergr_scan_plan(icebergr_scan(tbl, snapshot_id = first)))
#> [1] 1
nrow(icebergr_scan_plan(icebergr_scan(tbl)))
#> [1] 2
```

### Reading as of a time

`as_of` takes a time and resolves it to a snapshot:

``` r

icebergr_collect(
  icebergr_scan(tbl, as_of = history$timestamp[[1]], select = "id", limit = 3)
)
#> # A tibble: 3 × 1
#>      id
#>   <int>
#> 1     1
#> 2     2
#> 3     3
```

Two things about that argument are worth being explicit about, because
both are easy to get wrong.

**It is a commit time, not a time in your data.** `as_of` asks “what did
this table look like then”, not “which rows are from then”. A `day` or
`recorded_at` column is data; filter on it with `filter`.

**It resolves against the snapshot log, not the snapshot list.** Iceberg
keeps both: the list of every snapshot that still exists, and the *log*
of which snapshot was current at which time. A rollback removes an entry
from the log while leaving the snapshot in the list. Resolving against
the list would find an abandoned snapshot with a matching timestamp and
read a state the table was rolled back *out of*; `icebergr` resolves
against the log, so it does not.

The same applies to a snapshot that only ever existed on another branch
— present in the list, never in this branch’s log, therefore never
selected by `as_of`. It is still reachable by id, which is the right
split: an explicit id is a request for a specific state, while a time is
a request for the state this table was in.

### The schema travels too

Iceberg records a schema per snapshot, so a column that has since been
renamed or dropped is still nameable as of the snapshot that had it:

``` r

identical(
  icebergr_schema(tbl, snapshot_id = first)$name,
  icebergr_schema(tbl)$name
)
#> [1] TRUE
```

Nothing was renamed here, so the two agree. Where they would not,
`filter` and `select` are resolved against the schema of the snapshot
actually being read — not the current one. That is what makes a
historical read reproducible: the names that worked then still work, and
you do not have to know what happened to the schema in between.

### Isolation, and why a handle looks stale

A table handle is bound to a snapshot. Another session’s commit does not
change what your handle reads:

``` r

current <- icebergr_snapshots(tbl)
tbl2 <- icebergr_reload(tbl)
identical(nrow(icebergr_snapshots(tbl2)), nrow(current))
#> [1] TRUE
```

[`icebergr_reload()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_reload.md)
is how you opt in to seeing new commits. Until you call it, every scan
off that handle reads one consistent state — snapshot isolation in the
sense of Berenson et al. (1995), obtained from immutability rather than
from locking. All three lakehouse formats get it the same way (Jain et
al. 2023).

The practical consequence: two scans off the same handle are guaranteed
to agree, which is what you want when a report runs several queries and
has to add up.

### What is not here

Snapshot expiry — deleting old snapshots and the files only they
reference — is a maintenance operation this version does not expose, and
neither is rollback itself. Both need transaction actions `iceberg-rust`
0.10.0 does not provide:

``` r

features <- icebergr_spec_support()$features
features[
  grepl("snapshot|expiry|rollback", features$feature, ignore.case = TRUE),
  c("feature", "supported", "reason")
]
#> # A tibble: 2 × 3
#>   feature              supported reason
#>   <chr>                <lgl>     <chr> 
#> 1 Snapshot time travel TRUE      NA    
#> 2 Snapshot history     TRUE      NA
```

Reading a table that another engine has rolled back or expired works
normally. Time travel is a read capability, and this package has all of
it.

## References

Berenson, Hal, Philip A. Bernstein, Jim Gray, Jim Melton, Elizabeth J.
O’Neil, and Patrick E. O’Neil. 1995. “A Critique of ANSI SQL Isolation
Levels.” *Proceedings of the 1995 ACM SIGMOD International Conference on
Management of Data*, 1–10. <https://doi.org/10.1145/223784.223785>.

Jain, Paras, Peter Kraft, Conor Power, Tathagata Das, Ion Stoica, and
Matei Zaharia. 2023. “Analyzing and Comparing Lakehouse Storage
Systems.” *Proceedings of the 13th Conference on Innovative Data Systems
Research (CIDR)*. <https://www.cidrdb.org/cidr2023/papers/p92-jain.pdf>.

The Apache Software Foundation. 2026. *Apache Iceberg Table Spec*.
Apache Iceberg documentation. <https://iceberg.apache.org/spec/>.
