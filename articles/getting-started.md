# Getting started with icebergr

Every example here runs offline against a table built on your own
machine. No catalog server, no network, no credentials.

``` r

library(icebergr)
```

### What this package is for

Iceberg (The Apache Software Foundation 2026a) is the open table format
that Snowflake, Databricks, BigQuery, AWS and Dremio have all
standardised on. Apache maintains clients for Java, Python, Rust and Go
— but not R, which has been able to read Iceberg tables only by routing
through DuckDB (Raasveldt and Mühleisen 2019). That rules out writes,
snapshot management, schema access and catalog integration.

`icebergr` binds `iceberg-rust` (The Apache Software Foundation 2026b)
directly through extendr (The extendr authors 2026). Arrow is the
interchange layer, so scan results arrive in R over the C stream
interface (The Apache Software Foundation 2026c) without a serialisation
round trip.

[`vignette("table-format")`](https://pursuitofdatascience.github.io/icebergr/articles/table-format.md)
explains the format itself, and why a client rather than an exporter is
the thing worth having.

### A table to work with

[`icebergr_example_table()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_example_table.md)
builds a real Iceberg table in a temporary warehouse directory: two
appends, so there is history to travel through and more than one data
file for a filter to prune.

``` r

tbl <- icebergr_example_table(rows = 200)
show(tbl)
#> <icebergr_table>
#>   table:    db.events
#>   location: <tempdir>/icebergr-warehouse2b226488bcff/db/events
#>   format:   v2
#>   snapshot: 8183190700905976539
#>   columns:  5
#>     id <int>
#>     event <string>
#>     amount <double>
#>     day <date>
#>     recorded_at <timestamptz>
```

It is generated rather than shipped because Iceberg records absolute
paths in its metadata and its Avro manifests — a table built on one
machine does not resolve on another.

### Inspecting a table

``` r

icebergr_schema(tbl)
#> # A tibble: 5 × 5
#>   field_id name        type        required doc  
#>      <int> <chr>       <chr>       <lgl>    <chr>
#> 1        1 id          int         FALSE    NA   
#> 2        2 event       string      FALSE    NA   
#> 3        3 amount      double      FALSE    NA   
#> 4        4 day         date        FALSE    NA   
#> 5        5 recorded_at timestamptz FALSE    NA
```

`type` is the Iceberg type, not the R type. The mapping to R happens on
read.

An unpartitioned table returns zero partition fields:

``` r

icebergr_partitions(tbl)
#> # A tibble: 0 × 6
#> # ℹ 6 variables: spec_id <int>, field_id <int>, name <chr>, transform <chr>,
#> #   source_id <int>, source_name <chr>
```

### Reading

[`icebergr_scan()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_scan.md)
describes a read;
[`icebergr_collect()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_collect.md)
performs it.

``` r

icebergr_collect(icebergr_scan(tbl, limit = 5))
#> # A tibble: 5 × 5
#>      id event    amount day        recorded_at        
#>   <int> <chr>     <dbl> <date>     <dttm>             
#> 1  1001 purchase   500  2024-06-01 2024-06-01 00:00:00
#> 2  1002 refund     503. 2024-06-02 2024-06-01 01:00:00
#> 3  1003 purchase   505. 2024-06-03 2024-06-01 02:00:00
#> 4  1004 refund     508. 2024-06-04 2024-06-01 03:00:00
#> 5  1005 purchase   510. 2024-06-05 2024-06-01 04:00:00
```

Scanning the whole table is common enough to have a shorthand:

``` r

nrow(icebergr_collect(tbl))
#> [1] 400
```

#### Pushdown

`filter` and `select` are pushed into scan planning. This is the entire
performance argument for Iceberg over reading raw Parquet: manifests
carry per-file statistics, so whole files and row groups are eliminated
before any bytes are read.

``` r

icebergr_collect(
  icebergr_scan(
    tbl,
    filter = id > 1000 & amount > 900,
    select = c("id", "event", "amount")
  )
)
#> # A tibble: 40 × 3
#>       id event    amount
#>    <int> <chr>     <dbl>
#>  1  1161 purchase   902.
#>  2  1162 refund     905.
#>  3  1163 purchase   907.
#>  4  1164 refund     910.
#>  5  1165 purchase   912.
#>  6  1166 refund     915.
#>  7  1167 purchase   917.
#>  8  1168 refund     920.
#>  9  1169 purchase   922.
#> 10  1170 refund     925.
#> # ℹ 30 more rows
```

Filters may use `==`, `!=`, `<`, `<=`, `>`, `>=`, `&`, `|`, `!`, `%in%`,
[`is.na()`](https://rdrr.io/r/base/NA.html),
[`is.nan()`](https://rdrr.io/r/base/is.finite.html) and
[`startsWith()`](https://rdrr.io/r/base/startsWith.html) – the last only
against a `string` column, since Iceberg defines a prefix comparison for
no other type. A bare name is read as a column when the table has one of
that name, and otherwise evaluated in the calling environment:

``` r

# The second append holds ids 1001 to 1200, so this keeps the last fifty.
threshold <- 1150
icebergr_collect(icebergr_scan(tbl, filter = id > threshold, select = "id"))
#> # A tibble: 50 × 1
#>       id
#>    <int>
#>  1  1151
#>  2  1152
#>  3  1153
#>  4  1154
#>  5  1155
#>  6  1156
#>  7  1157
#>  8  1158
#>  9  1159
#> 10  1160
#> # ℹ 40 more rows
```

Anything more elaborate is refused rather than quietly ignored, so you
always know whether a filter was pushed down:

``` r

icebergr_collect(icebergr_scan(tbl, filter = sqrt(amount) > 10))
#> Error in `icebergr_scan()`:
#> ! Cannot push this filter down to Iceberg: neither side of `sqrt(amount) > 10` names a column of the table. Columns are: id, event, amount, day, recorded_at.
#> ℹ Supported: ==, !=, <, <=, >, >=, &, |, !, %in%, is.na(), is.nan() and startsWith().
#> ℹ Anything else can be applied in R after icebergr_collect().
```

#### Verifying that pushdown happened

Comparing results proves nothing: a filter applied in R afterwards gives
the same rows. What distinguishes pushdown is how much was planned to be
read.

``` r

icebergr_scan_plan(icebergr_scan(tbl))[, c("record_count", "file_size_in_bytes")]
#> # A tibble: 2 × 2
#>   record_count file_size_in_bytes
#>          <dbl>              <dbl>
#> 1          200               4901
#> 2          200               4998
```

``` r

icebergr_scan_plan(icebergr_scan(tbl, filter = id > 1000))[, c("record_count")]
#> # A tibble: 1 × 1
#>   record_count
#>          <dbl>
#> 1          200
```

Fewer files, and fewer records, than the table holds.

#### One caveat about `limit`

`limit` is **not** pushdown. `iceberg-rust` has no row limit in its scan
API, so the same files are planned and rows are counted as batches
arrive. It bounds how much is decoded, not how much is planned.
[`print()`](https://rdrr.io/r/base/print.html) says so:

``` r

icebergr_scan(tbl, filter = id > 1000, limit = 10)
#> <icebergr_scan>
#>   table:    db.events
#>   select:   <all columns>
#>   filter:   id > 1000 (pushed down)
#>   limit:    10 (applied after the scan, not pushed down)
#>   Use icebergr_collect() to read it.
```

### Time travel

Every write creates a snapshot.

``` r

history <- icebergr_snapshots(tbl)
history[, c("snapshot_id", "operation", "added_records", "total_records")]
#> # A tibble: 2 × 4
#>   snapshot_id         operation added_records total_records
#>   <chr>               <chr>             <dbl>         <dbl>
#> 1 5807927327002716758 append              200           200
#> 2 8183190700905976539 append              200           400
```

Snapshot ids are **character**, not numeric. Iceberg assigns them as
random 64-bit integers, and an R numeric carries only 53 bits, so
passing one through a double would silently select the wrong snapshot.

Read an earlier state by id:

``` r

nrow(icebergr_collect(icebergr_scan(tbl, snapshot_id = history$snapshot_id[[1]])))
#> [1] 200
```

Or by time, which is resolved against the history to the snapshot that
was current at that moment:

``` r

nrow(icebergr_collect(icebergr_scan(tbl, as_of = history$timestamp[[1]])))
#> [1] 200
```

Iceberg records a schema per snapshot, so `filter` and `select` are
resolved against the schema of the snapshot actually being read rather
than the current one. A column another engine has since renamed or
dropped is therefore still nameable as of the snapshot that had it, and
[`icebergr_schema()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_schema.md)
will show you what those columns were:

``` r

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

### Writing

Writes are append-only. Nothing already in the table is rewritten or
removed.

``` r

new_rows <- data.frame(
  id = c(9001L, 9002L),
  event = c("purchase", "refund"),
  amount = c(42.5, -12.25),
  day = as.Date(c("2024-07-01", "2024-07-02")),
  recorded_at = as.POSIXct(c("2024-07-01 09:00:00", "2024-07-02 10:30:00"), tz = "UTC")
)

tbl <- icebergr_append(tbl, new_rows)
nrow(icebergr_collect(tbl))
#> [1] 402
```

[`icebergr_append()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_append.md)
returns an *updated* handle rather than mutating the old one, so
reassign it. The old handle still reads the older snapshot, which is
occasionally useful and never surprising.

Columns are matched by name, not position, so order does not matter. A
column the table does not have is an error rather than a silent drop:

``` r

icebergr_append(tbl, transform(new_rows, unexpected = 1))
#> Error in `rs_table_append()`:
#> ! the data has 1 column(s) that the table does not: unexpected.
#> Table columns are: amount, day, event, id, recorded_at.
```

#### Creating a table

A data frame is enough to define a schema. Only the column names and
types are used; no rows are written.

``` r

warehouse <- tempfile("warehouse")
dir.create(warehouse)

catalog <- icebergr_catalog("memory", warehouse = warehouse)
icebergr_create_namespace(catalog, "analytics")

measurements <- data.frame(
  sensor = character(),
  reading = double(),
  taken_at = as.POSIXct(character(), tz = "UTC")
)

sensors <- icebergr_create_table(catalog, "analytics.measurements", measurements)
icebergr_schema(sensors)
#> # A tibble: 3 × 5
#>   field_id name     type        required doc  
#>      <int> <chr>    <chr>       <lgl>    <chr>
#> 1        1 sensor   string      FALSE    NA   
#> 2        2 reading  double      FALSE    NA   
#> 3        3 taken_at timestamptz FALSE    NA
```

### Type fidelity

Most R types survive unchanged. The exception worth knowing is `factor`:
Iceberg has no dictionary type, so levels cannot be carried and values
come back as `character`.

``` r

types <- data.frame(
  i = 1L,
  d = 1.5,
  s = "text",
  b = TRUE,
  day = as.Date("2024-01-01"),
  ts = as.POSIXct("2024-01-01 12:00:00", tz = "UTC"),
  f = factor("a", levels = c("a", "b"))
)

type_tbl <- icebergr_create_table(catalog, "analytics.types", types)
type_tbl <- icebergr_append(type_tbl, types)

vapply(icebergr_collect(type_tbl), function(x) class(x)[[1]], character(1))
#>           i           d           s           b         day          ts 
#>   "integer"   "numeric" "character"   "logical"      "Date"   "POSIXct" 
#>           f 
#> "character"
```

### Knowing what is not supported

`icebergr` is deliberately narrow. Rather than discovering a gap at
runtime, ask:

``` r

support <- icebergr_spec_support()
support$spec_versions
#> [1] 1 2
```

``` r

features <- support$features
unsupported <- !is.na(features$supported) & !features$supported
features[unsupported, c("feature", "reason")]
#> # A tibble: 16 × 2
#>    feature                       reason                                         
#>    <chr>                         <chr>                                          
#>  1 AWS Glue catalog              Requires the optional 'glue' Cargo feature     
#>  2 Object storage (S3)           Requires the optional 's3' Cargo feature       
#>  3 Nested field pushdown         iceberg-rust cannot plan a scan filtered or pr…
#>  4 Table properties (write)      Needs an update_properties transaction; out of…
#>  5 Hadoop/filesystem catalog     Not implemented in iceberg-rust; use type = 'm…
#>  6 Row limit pushdown            iceberg-rust has no row limit in its scan API;…
#>  7 Row-level deletes (write)     iceberg-rust 0.10.0 can write an equality dele…
#>  8 MERGE / upsert                Needs row-level deletes plus an overwrite, nei…
#>  9 Overwrite writes              iceberg-rust 0.10.0 has no overwrite or rewrit…
#> 10 Schema evolution              Out of scope for icebergr 0.1.0                
#> 11 Partitioned table creation    Out of scope for icebergr 0.1.0                
#> 12 Append to a partitioned table An append would have to compute a partition va…
#> 13 Partition evolution           Out of scope for icebergr 0.1.0                
#> 14 Compaction / maintenance      Compaction needs a rewrite action iceberg-rust…
#> 15 dbplyr lazy verbs             Out of scope for icebergr 0.1.0                
#> 16 Table encryption              Not exposed in icebergr 0.1.0
```

Some of those are absent from `iceberg-rust` itself, not just from this
package; the `reason` column says which.

### Where next

Five vignettes go deeper on one theme each:

- [`vignette("table-format")`](https://pursuitofdatascience.github.io/icebergr/articles/table-format.md)
  — what Iceberg is, and what it fixes
- [`vignette("pushdown")`](https://pursuitofdatascience.github.io/icebergr/articles/pushdown.md)
  — how a filter prunes files and row groups
- [`vignette("time-travel")`](https://pursuitofdatascience.github.io/icebergr/articles/time-travel.md)
  — snapshots, timestamps and rollbacks
- [`vignette("writing")`](https://pursuitofdatascience.github.io/icebergr/articles/writing.md)
  — appends, table creation, and what is refused
- [`vignette("types")`](https://pursuitofdatascience.github.io/icebergr/articles/types.md)
  — the R, Arrow and Iceberg type correspondence
- [`vignette("catalog-configuration")`](https://pursuitofdatascience.github.io/icebergr/articles/catalog-configuration.md)
  — REST, AWS Glue, object storage, and how credentials are handled

## References

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

The extendr authors. 2026. *Extendr: A Safe and User-Friendly R
Extension Interface Using Rust*. <https://extendr.github.io/>.
