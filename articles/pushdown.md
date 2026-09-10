# Predicate and Projection Pushdown

Pushdown is the reason to read an Iceberg table through a client rather
than collect it and subset in R. `filter` and `select` travel with the
scan into `iceberg-rust`, which uses them to decide what to open — so
the saving is in bytes never read, not in rows discarded afterwards.

This vignette shows the three levels at which that happens, and how to
verify each of them rather than assume it.

``` r

tbl <- icebergr_example_table(rows = 200)
```

### The three levels

| Level | Uses | Effect |
|----|----|----|
| File | per-column bounds in the Iceberg manifest | a file is never opened |
| Row group | statistics in the Parquet footer | a block within a file is skipped |
| Row | the filter, re-applied during decode | non-matching rows are dropped |

The first two are *pruning* and cost nothing: the bounds were written at
commit time. Only the third touches the data. The equivalent
measurements for column stores in general are in Abadi et al. (2008),
and for Parquet and ORC specifically, with their present-day encodings,
in Zeng et al. (2023).

### File pruning, measured

[`icebergr_scan_plan()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_scan_plan.md)
returns the file tasks a scan would execute, without executing them.
Comparing two plans is how you confirm a predicate was actually pushed
down:

``` r

all_files <- icebergr_scan_plan(icebergr_scan(tbl))
hot_files <- icebergr_scan_plan(icebergr_scan(tbl, filter = id > 1000))

nrow(all_files)
#> [1] 2
nrow(hot_files)
#> [1] 1
```

The example table is built with two appends, so there are two data files
and the second holds the higher ids. A filter that only the second can
satisfy plans one file instead of two:

``` r

all_files[, c("record_count", "file_size_in_bytes")]
#> # A tibble: 2 × 2
#>   record_count file_size_in_bytes
#>          <dbl>              <dbl>
#> 1          200               4901
#> 2          200               4998
hot_files[, c("record_count", "file_size_in_bytes")]
#> # A tibble: 1 × 2
#>   record_count file_size_in_bytes
#>          <dbl>              <dbl>
#> 1          200               4901
```

`record_count` is the count *before* filtering — it is what the manifest
recorded when the file was written. A plan is a statement about what
will be opened, not about what will come back.

A predicate no file can satisfy prunes everything:

``` r

nrow(icebergr_scan_plan(icebergr_scan(tbl, filter = id > 10^6)))
#> [1] 0
```

### Projection pushdown

`select` never reaches the row level at all, because a columnar file
lets the reader seek to the columns it wants and ignore the rest. This
is Dremel’s layout (Melnik et al. 2010), and it is why the column list
matters as much as the predicate:

``` r

narrow <- icebergr_collect(
  icebergr_scan(tbl, select = c("id", "amount"), limit = 3)
)
narrow
#> # A tibble: 3 × 2
#>      id amount
#>   <int>  <dbl>
#> 1  1001   500 
#> 2  1002   503.
#> 3  1003   505.
```

The other columns are not decoded, not converted, and not allocated in
R.

### Which predicates push down

`filter` is an R expression, translated into an Iceberg predicate. What
is translatable is a closed list — `==`, `!=`, `<`, `<=`, `>`, `>=`,
`&`, `|`, `!`, `%in%`, [`is.na()`](https://rdrr.io/r/base/NA.html),
[`is.nan()`](https://rdrr.io/r/base/is.finite.html) and
[`startsWith()`](https://rdrr.io/r/base/startsWith.html):

``` r

icebergr_collect(
  icebergr_scan(tbl,
    filter = event %in% c("purchase", "refund") & amount > 900,
    select = c("event", "amount"), limit = 5
  )
)
#> # A tibble: 5 × 2
#>   event    amount
#>   <chr>     <dbl>
#> 1 purchase   902.
#> 2 refund     905.
#> 3 purchase   907.
#> 4 refund     910.
#> 5 purchase   912.
```

A bare name is read as a column when the table has one of that name, and
otherwise evaluated in the calling environment — so a local variable
works without any quoting ceremony:

``` r

threshold <- 950
icebergr_collect(
  icebergr_scan(tbl, filter = amount > threshold, select = "amount", limit = 3)
)
#> # A tibble: 3 × 1
#>   amount
#>    <dbl>
#> 1   952.
#> 2   955.
#> 3   957.
```

Anything outside that list belongs in R, after collecting. There is no
partial credit: an expression the translator does not recognise is an
error rather than a silently unpushed filter, because a filter that
quietly stopped pruning would look like nothing more than a slow scan.

### Three things that do not push down

**`limit` bounds decoding, not planning.** `iceberg-rust` 0.10.0 has no
row limit in its scan API, so every file the predicate admits is still
planned:

``` r

nrow(icebergr_scan_plan(icebergr_scan(tbl, limit = 1)))
#> [1] 2
```

The rows are counted as batches arrive, which does save conversion into
R, but not I/O. Use a predicate to reduce I/O.

**A filter on a nested field.** Iceberg cannot push a predicate onto a
field inside a `struct`; read the parent column and subset it in R.

**A `decimal` ordering comparison, at the row level only.** It is pushed
down, but with `iceberg-rust`’s row-level selection turned off for that
scan, because in 0.10.0 that stage drops every row of an ordering
comparison against a decimal. File and row-group pruning still apply, so
the scan is slightly less selective and still correct.
[`icebergr_spec_support()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_spec_support.md)
records this as a known upstream limitation rather than leaving it to be
discovered:

``` r

features <- icebergr_spec_support()$features
features[
  grepl("decimal|limit", features$feature, ignore.case = TRUE),
  c("feature", "supported", "reason")
]
#> # A tibble: 2 × 3
#>   feature            supported reason                                           
#>   <chr>              <lgl>     <chr>                                            
#> 1 Decimal predicates TRUE      Row-level selection is disabled for these scans;…
#> 2 Row limit pushdown FALSE     iceberg-rust has no row limit in its scan API; l…
```

### Case sensitivity

Iceberg column names are case-sensitive, and `case_sensitive = FALSE`
prefers an exact match rather than taking the first hit. A table holding
both `id` and `ID` resolves each to itself; a name that matches two
columns and neither exactly is an error rather than a silent choice.

``` r

icebergr_collect(icebergr_scan(tbl,
  select = "ID", case_sensitive = FALSE,
  limit = 2
))
#> # A tibble: 2 × 1
#>      id
#>   <int>
#> 1     1
#> 2     2
```

### Reading a plan for cost, not just count

`file_size_in_bytes` is what the manifest recorded, so a plan gives an
I/O estimate before any read:

``` r

sum(all_files$file_size_in_bytes)
#> [1] 9899
sum(hot_files$file_size_in_bytes)
#> [1] 4901
```

On object storage that ratio is the one that matters, and it is
available without a single `GET` against the data. Query engines built
around this format use the same metadata for the same purpose (Behm et
al. 2022).

## References

Abadi, Daniel J., Samuel R. Madden, and Nabil Hachem. 2008.
“Column-Stores Vs. Row-Stores: How Different Are They Really?”
*Proceedings of the 2008 ACM SIGMOD International Conference on
Management of Data*, 967–80. <https://doi.org/10.1145/1376616.1376712>.

Behm, Alexander, Shoumik Palkar, Utkarsh Agarwal, et al. 2022. “Photon:
A Fast Query Engine for Lakehouse Systems.” *Proceedings of the 2022 ACM
SIGMOD International Conference on Management of Data*, 2326–39.
<https://doi.org/10.1145/3514221.3526054>.

Melnik, Sergey, Andrey Gubarev, Jing Jing Long, et al. 2010. “Dremel:
Interactive Analysis of Web-Scale Datasets.” *Proceedings of the VLDB
Endowment* 3 (1-2): 330–39. <https://doi.org/10.14778/1920841.1920886>.

Zeng, Xinyu, Yulong Hui, Jiahong Shen, Andrew Pavlo, Wes McKinney, and
Huanchen Zhang. 2023. “An Empirical Evaluation of Columnar Storage
Formats.” *Proceedings of the VLDB Endowment* 17 (2): 148–61.
<https://doi.org/10.14778/3626292.3626298>.
