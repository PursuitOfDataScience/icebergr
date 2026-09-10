# What Iceberg Is, and What It Fixes

A table format is not a file format. Parquet says how one file is laid
out; Iceberg says which files constitute a table right now, what their
schema is, and what the table looked like an hour ago. This vignette is
about that distinction, because it is the reason reading Parquet is not
the same as reading an Iceberg table — and the reason `arrow` cannot
substitute for a client.

### The problem inherited from Hive

The original convention, from Hive (Thusoo et al. 2009), was that a
table *is* a directory, and a partition *is* a subdirectory. Everything
follows from that: to know what a table contains, list the filesystem.

Three consequences made it unworkable at scale, and they are what the
lakehouse table formats were designed against (Armbrust et al. 2021):

- **No atomicity.** A writer that must add ten files has no way to make
  the ten appear together. Readers see a partial commit.
- **Listing is the query plan.** Planning cost scales with the number of
  files and, on object storage, each listing is a network round trip
  with eventual consistency behind it.
- **Schema is a directory convention.** Renaming a column, or changing
  how a table is partitioned, means rewriting paths, so in practice
  nobody does it.

Delta Lake (Armbrust et al. 2020) and Iceberg (The Apache Software
Foundation 2026a) answer the same question in the same shape — keep the
file list in metadata, commit by swapping a pointer — and differ in how
that metadata is organised. A comparison of the three main
implementations, with a benchmark, is in Jain et al. (2023).

### What Iceberg keeps instead

Iceberg’s metadata is a tree, and every level of it is immutable:

| Level | Holds | Written as |
|----|----|----|
| Table metadata | current schema, partition specs, snapshot log, properties | JSON |
| Snapshot | one manifest list — the state of the table at one instant | referenced from the metadata |
| Manifest list | the manifests in this snapshot, with partition ranges | Avro |
| Manifest | data files, with per-column bounds, null counts and row counts | Avro |
| Data file | the rows | Parquet, ORC or Avro |

A commit writes new metadata and then atomically swaps the pointer to
it. Nothing is mutated, which is why a reader mid-commit sees the old
table rather than half of the new one, and why yesterday’s snapshot is
still readable today: it is still there, and still consistent.

`icebergr` exposes each level. The schema and partition spec come from
the table metadata:

``` r

tbl <- icebergr_example_table(rows = 200)

icebergr_schema(tbl)
#> # A tibble: 5 × 5
#>   field_id name        type        required doc  
#>      <int> <chr>       <chr>       <lgl>    <chr>
#> 1        1 id          int         FALSE    NA   
#> 2        2 event       string      FALSE    NA   
#> 3        3 amount      double      FALSE    NA   
#> 4        4 day         date        FALSE    NA   
#> 5        5 recorded_at timestamptz FALSE    NA
icebergr_partitions(tbl)
#> # A tibble: 0 × 6
#> # ℹ 6 variables: spec_id <int>, field_id <int>, name <chr>, transform <chr>,
#> #   source_id <int>, source_name <chr>
```

The snapshot log is the history:

``` r

icebergr_snapshots(tbl)[, c("snapshot_id", "operation", "added_records")]
#> # A tibble: 2 × 3
#>   snapshot_id         operation added_records
#>   <chr>               <chr>             <dbl>
#> 1 7996435829900474099 append              200
#> 2 4061902285022883340 append              200
```

And the manifests are what makes a scan plan possible without opening
any data file —
[`icebergr_scan_plan()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_scan_plan.md)
reads bounds out of the manifest, not out of Parquet:

``` r

plan <- icebergr_scan_plan(icebergr_scan(tbl))

# `data_file_path` is elided: it is an absolute path in a temporary
# warehouse, so it would differ on every machine.
plan[, c("record_count", "file_size_in_bytes")]
#> # A tibble: 2 × 2
#>   record_count file_size_in_bytes
#>          <dbl>              <dbl>
#> 1          200               4901
#> 2          200               4998
```

### Why the column statistics matter so much

Because per-column bounds live in the manifest, a filter can eliminate a
file before it is opened. That is the whole performance argument, and it
is inherited twice over: once from the manifest, and once from Parquet’s
own footer, whose row-group statistics allow the same trick within a
file.

The columnar layout underneath is Dremel’s (Melnik et al. 2010) —
repetition and definition levels, which is how a nested `struct` or
`list` survives being stored one column at a time. The gains from
reading only the columns a query needs, and only the row ranges that can
match, are the ones measured for column stores generally in Abadi et al.
(2008), and re-measured for Parquet and ORC specifically, with their
modern encodings, in Zeng et al. (2023).

[`vignette("pushdown")`](https://pursuitofdatascience.github.io/icebergr/articles/pushdown.md)
shows what `icebergr` pushes down and how to confirm it happened.

### Concurrency, without a lock server

Iceberg commits optimistically: a writer reads the current metadata,
prepares a new snapshot, and swaps the pointer only if the pointer has
not moved. If it has, the commit fails and is retried. All three
lakehouse formats work this way (Jain et al. 2023).

What a reader gets from this is snapshot isolation in the sense of
Berenson et al. (1995): a scan runs entirely against one snapshot, so a
long-running read never observes a write that landed halfway through it.
In `icebergr` this is explicit rather than incidental, because a table
handle *is* a snapshot. Another session’s commit is invisible until you
ask for it:

``` r

tbl <- icebergr_reload(tbl) # now points at the newest snapshot
```

That is a feature, not a staleness bug — two scans off the same handle
are guaranteed to agree.

### Where R sits in this

The design that makes an R client possible at all is the one described
in Pedreira et al. (2023): a data system decomposed into reusable
components with Arrow as the interchange format between them, rather
than a monolith with one front end. `icebergr` uses three of those
components — `iceberg-rust` (The Apache Software Foundation 2026b) for
metadata and planning, Parquet readers underneath it, and the Arrow C
stream interface (The Apache Software Foundation 2026c) to hand the
result to R — and adds no execution engine of its own.

The alternative route, reading Iceberg through DuckDB (Raasveldt and
Mühleisen 2019), is a good one for queries and remains available. What
it cannot do is write, commit, manage snapshots, or read the schema of a
snapshot that is no longer current, because those are table-format
operations rather than query operations. Engines whose whole design
centres on this format — Photon, for instance (Behm et al. 2022) — treat
the metadata as a first-class input for exactly that reason.

### What this package does not do

Iceberg’s spec is larger than any single client implements, and this
package is narrower than `iceberg-rust`.
[`icebergr_spec_support()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_spec_support.md)
reports the boundary for your own build, and distinguishes the two cases
— missing here, versus missing upstream:

``` r

support <- icebergr_spec_support()
features <- support$features
head(features[
  !is.na(features$supported) & !features$supported,
  c("feature", "reason")
], 8)
#> # A tibble: 8 × 2
#>   feature                   reason                                              
#>   <chr>                     <chr>                                               
#> 1 AWS Glue catalog          Requires the optional 'glue' Cargo feature          
#> 2 Object storage (S3)       Requires the optional 's3' Cargo feature            
#> 3 Nested field pushdown     iceberg-rust cannot plan a scan filtered or project…
#> 4 Table properties (write)  Needs an update_properties transaction; out of scop…
#> 5 Hadoop/filesystem catalog Not implemented in iceberg-rust; use type = 'memory'
#> 6 Row limit pushdown        iceberg-rust has no row limit in its scan API; limi…
#> 7 Row-level deletes (write) iceberg-rust 0.10.0 can write an equality delete fi…
#> 8 MERGE / upsert            Needs row-level deletes plus an overwrite, neither …
```

Reading a table another engine wrote with features this package does not
implement still works, as long as the scan does not need them. That is
the property the format was designed to have.

## References

Abadi, Daniel J., Samuel R. Madden, and Nabil Hachem. 2008.
“Column-Stores Vs. Row-Stores: How Different Are They Really?”
*Proceedings of the 2008 ACM SIGMOD International Conference on
Management of Data*, 967–80. <https://doi.org/10.1145/1376616.1376712>.

Armbrust, Michael, Tathagata Das, Sameer Paranjpye, et al. 2020. “Delta
Lake: High-Performance ACID Table Storage over Cloud Object Stores.”
*Proceedings of the VLDB Endowment* 13 (12): 3411–24.
<https://doi.org/10.14778/3415478.3415560>.

Armbrust, Michael, Ali Ghodsi, Reynold Xin, and Matei Zaharia. 2021.
“Lakehouse: A New Generation of Open Platforms That Unify Data
Warehousing and Advanced Analytics.” *Proceedings of the 11th Conference
on Innovative Data Systems Research (CIDR)*.
<https://www.cidrdb.org/cidr2021/papers/cidr2021_paper17.pdf>.

Behm, Alexander, Shoumik Palkar, Utkarsh Agarwal, et al. 2022. “Photon:
A Fast Query Engine for Lakehouse Systems.” *Proceedings of the 2022 ACM
SIGMOD International Conference on Management of Data*, 2326–39.
<https://doi.org/10.1145/3514221.3526054>.

Berenson, Hal, Philip A. Bernstein, Jim Gray, Jim Melton, Elizabeth J.
O’Neil, and Patrick E. O’Neil. 1995. “A Critique of ANSI SQL Isolation
Levels.” *Proceedings of the 1995 ACM SIGMOD International Conference on
Management of Data*, 1–10. <https://doi.org/10.1145/223784.223785>.

Jain, Paras, Peter Kraft, Conor Power, Tathagata Das, Ion Stoica, and
Matei Zaharia. 2023. “Analyzing and Comparing Lakehouse Storage
Systems.” *Proceedings of the 13th Conference on Innovative Data Systems
Research (CIDR)*. <https://www.cidrdb.org/cidr2023/papers/p92-jain.pdf>.

Melnik, Sergey, Andrey Gubarev, Jing Jing Long, et al. 2010. “Dremel:
Interactive Analysis of Web-Scale Datasets.” *Proceedings of the VLDB
Endowment* 3 (1-2): 330–39. <https://doi.org/10.14778/1920841.1920886>.

Pedreira, Pedro, Orri Erling, Konstantinos Karanasos, et al. 2023. “The
Composable Data Management System Manifesto.” *Proceedings of the VLDB
Endowment* 16 (10): 2679–85. <https://doi.org/10.14778/3603581.3603604>.

Raasveldt, Mark, and Hannes Mühleisen. 2019. “DuckDB: An Embeddable
Analytical Database.” *Proceedings of the 2019 ACM SIGMOD International
Conference on Management of Data*, 1981–84.
<https://doi.org/10.1145/3299869.3320212>.

The Apache Software Foundation. 2026a. *Apache Iceberg Table Spec*.
Apache Iceberg documentation. <https://iceberg.apache.org/spec/>.

The Apache Software Foundation. 2026b. *iceberg-rust: Apache Iceberg
Official Native Rust Implementation*.
<https://github.com/apache/iceberg-rust>.

The Apache Software Foundation. 2026c. *The Arrow C Data Interface and C
Stream Interface*. Apache Arrow documentation.
<https://arrow.apache.org/docs/format/CDataInterface.html>.

Thusoo, Ashish, Joydeep Sen Sarma, Namit Jain, et al. 2009. “Hive: A
Warehousing Solution over a Map-Reduce Framework.” *Proceedings of the
VLDB Endowment* 2 (2): 1626–29.
<https://doi.org/10.14778/1687553.1687609>.

Zeng, Xinyu, Yulong Hui, Jiahong Shen, Andrew Pavlo, Wes McKinney, and
Huanchen Zhang. 2023. “An Empirical Evaluation of Columnar Storage
Formats.” *Proceedings of the VLDB Endowment* 17 (2): 148–61.
<https://doi.org/10.14778/3626292.3626298>.
