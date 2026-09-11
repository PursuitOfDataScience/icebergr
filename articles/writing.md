# Writing: Appends, Tables and What Is Refused

Writing is the capability that routing through a query engine does not
give you (Raasveldt and Mühleisen 2019): a commit is a table-format
operation, not a query. This version writes appends, creates tables and
namespaces, and registers existing tables. Everything it will not do, it
refuses before writing anything.

Every example here runs against a local warehouse on your own machine.

``` r

warehouse <- file.path(tempdir(), "icebergr-writing")
dir.create(warehouse, showWarnings = FALSE)

catalog <- icebergr_catalog("memory", warehouse = warehouse)
show(catalog)
#> <icebergr_catalog>
#>   type:      memory
#>   name:      icebergr
#>   warehouse: <tempdir>/icebergr-writing
```

The `memory` catalog keeps its table pointers in the R session and its
data on disk. It needs no server, which makes it the right thing for
tests and for scratch work;
[`vignette("catalog-configuration")`](https://pursuitofdatascience.github.io/icebergr/articles/catalog-configuration.md)
covers REST and AWS Glue, which are what you use when the table has to
outlive the session.

### A namespace, then a table

``` r

icebergr_create_namespace(catalog, "shop")
icebergr_list_namespaces(catalog)
#> [1] "shop"
```

[`icebergr_create_table()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_create_table.md)
takes a data frame, but **only to read its schema off — no rows are
written**. The new table is empty, with no snapshot at all:

``` r

template <- data.frame(
  id = integer(),
  item = character(),
  amount = double(),
  day = as.Date(character())
)

orders <- icebergr_create_table(catalog, "shop.orders", template)
show(orders)
#> <icebergr_table>
#>   table:    shop.orders
#>   location: <tempdir>/icebergr-writing/shop/orders
#>   format:   v2
#>   snapshot: <none>
#>   columns:  4
#>     id <int>
#>     item <string>
#>     amount <double>
#>     day <date>
```

`snapshot: <none>` is the tell. An Iceberg table with no commits is a
legitimate state — schema and no data — and it is what you get here. The
rows come next.

### Appending

``` r

orders <- icebergr_append(orders, data.frame(
  id = 1:3,
  item = c("mug", "kettle", "mug"),
  amount = c(9.5, 42, 9.5),
  day = as.Date("2026-07-01") + 0:2
))

icebergr_collect(orders)
#> # A tibble: 3 × 4
#>      id item   amount day       
#>   <int> <chr>   <dbl> <date>    
#> 1     1 mug       9.5 2026-07-01
#> 2     2 kettle   42   2026-07-02
#> 3     3 mug       9.5 2026-07-03
```

[`icebergr_append()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_append.md)
returns a *new* handle, pointing at the snapshot the append created.
Reassigning is not optional bookkeeping — the old handle still reads the
old snapshot, by design:

``` r

orders <- icebergr_append(orders, data.frame(
  id = 4L, item = "cafetiere", amount = 24.5, day = as.Date("2026-07-04")
))

icebergr_snapshots(orders)[, c("operation", "added_records", "total_records")]
#> # A tibble: 2 × 3
#>   operation added_records total_records
#>   <chr>             <dbl>         <dbl>
#> 1 append                3             3
#> 2 append                1             4
```

Two appends, two snapshots, and
[`vignette("time-travel")`](https://pursuitofdatascience.github.io/icebergr/articles/time-travel.md)
can read either.

#### Compression

`compression` picks the Parquet codec, defaulting to `zstd`:

``` r

orders <- icebergr_append(
  orders,
  data.frame(id = 5L, item = "grinder", amount = 60, day = as.Date("2026-07-05")),
  compression = "snappy"
)

nrow(icebergr_collect(orders))
#> [1] 5
```

Which codec to prefer is a decode-speed against file-size trade, and it
is measured across the open formats in Zeng et al. (2023): dictionary
encoding does most of the work, and block compression on top of it buys
less than it used to. `zstd` is a reasonable default for cold data;
`snappy` decodes faster.

### Commits are atomic, and optimistic

An append writes its Parquet, writes new manifests, and then swaps the
table pointer — one atomic step, whose failure mode is that nothing
happened rather than that half of it did. If another writer committed in
between, the swap is rejected and retried against the new state, which
is how all three lakehouse formats handle concurrency (Armbrust et al.
2020; Jain et al. 2023).

For a reader this is the property that matters: a scan never sees a
partial append. That guarantee is the format’s, not this package’s, and
it is the reason the Hive directory convention had to be replaced
(Thusoo et al. 2009; Armbrust et al. 2021).

### Registering a table someone else wrote

[`icebergr_register_table()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_register_table.md)
adds an existing table to a catalog from its metadata file, without
moving or rewriting data:

``` r

icebergr_register_table(
  catalog, "shop.archive",
  "s3://warehouse/shop/archive/metadata/00007-8b1c….metadata.json"
)
```

The file has to be named the way every Iceberg engine names them —
`<version>-<uuid>.metadata.json`, because the next version number is
derived from that name. A renamed file registers and reads perfectly
well; it is the *append* that cannot work.

That append is refused at the start, before any Parquet is written, and
the error names the file. Left to Iceberg the name is only inspected
when the commit is attempted — by which point the data files are already
in the warehouse, and this package exposes no maintenance operation to
clear them.

It also has to sit inside the catalog’s warehouse, which is what
`confine = TRUE` — the default — requires. A metadata file names
absolute paths for its data, so one from an untrusted source reads
whatever its author chose; pass `confine = FALSE` only for a file you
trust.

### What is refused, and why that is the design

Three write operations are unavailable, and each fails before touching
the warehouse:

``` r

features <- icebergr_spec_support()$features
writes <- grepl("append|delete|merge|overwrite|partition|propert",
  features$feature,
  ignore.case = TRUE
)
features[
  writes & !is.na(features$supported) & !features$supported,
  c("feature", "reason")
]
#> # A tibble: 7 × 2
#>   feature                       reason                                          
#>   <chr>                         <chr>                                           
#> 1 Table properties (write)      Needs an update_properties transaction; out of …
#> 2 Row-level deletes (write)     iceberg-rust 0.10.0 can write an equality delet…
#> 3 MERGE / upsert                Needs row-level deletes plus an overwrite, neit…
#> 4 Overwrite writes              iceberg-rust 0.10.0 has no overwrite or rewrite…
#> 5 Partitioned table creation    Out of scope for this version of icebergr       
#> 6 Append to a partitioned table An append would have to compute a partition val…
#> 7 Partition evolution           Out of scope for this version of icebergr
```

**Appending to a partitioned table.** Iceberg only discovers a missing
partition value at commit time, which would leave orphan Parquet in the
warehouse and report the cause in terms of neither the table nor the
file. So the partition spec is checked first, and the append is refused
with nothing written. Reading a partitioned table works, and
[`icebergr_partitions()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_partitions.md)
reports its spec.

**Row-level deletes and `MERGE`.** `iceberg-rust` 0.10.0 can write an
equality delete file but has no transaction action that commits one.
Reading merge-on-read tables another engine wrote works — both
positional and equality deletes are applied.

**Overwrites.** `fast_append` is the only way 0.10.0 can add files to a
table.

That split — refuse loudly here, read whatever anyone else wrote — is
deliberate. A narrow surface that is correct is worth more than a broad
one that commits something subtly wrong, and the format is designed so
that a client which does not implement a feature can still read tables
that use it (The Apache Software Foundation 2026).

### Checking before you write

``` r

icebergr_table_exists(catalog, "shop.orders")
#> [1] TRUE
icebergr_table_exists(catalog, "shop.nothing_here")
#> [1] FALSE

icebergr_list_tables(catalog, "shop")
#> [1] "orders"
```

[`icebergr_properties()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_properties.md)
reads the table’s properties, and returns a zero-row tibble when it has
none — as a freshly created table does:

``` r

icebergr_properties(orders)
#> # A tibble: 0 × 2
#> # ℹ 2 variables: name <chr>, value <chr>
```

Setting them needs an `update_properties` transaction, which is also out
of scope for this version.

## References

Armbrust, Michael, Tathagata Das, Sameer Paranjpye, et al. 2020. “Delta
Lake: High-Performance ACID Table Storage over Cloud Object Stores.”
*Proceedings of the VLDB Endowment* 13 (12): 3411–24.
<https://doi.org/10.14778/3415478.3415560>.

Armbrust, Michael, Ali Ghodsi, Reynold Xin, and Matei Zaharia. 2021.
“Lakehouse: A New Generation of Open Platforms That Unify Data
Warehousing and Advanced Analytics.” *Proceedings of the 11th Conference
on Innovative Data Systems Research (CIDR)*.
<https://www.cidrdb.org/cidr2021/papers/cidr2021_paper17.pdf>.

Jain, Paras, Peter Kraft, Conor Power, Tathagata Das, Ion Stoica, and
Matei Zaharia. 2023. “Analyzing and Comparing Lakehouse Storage
Systems.” *Proceedings of the 13th Conference on Innovative Data Systems
Research (CIDR)*. <https://www.cidrdb.org/cidr2023/papers/p92-jain.pdf>.

Raasveldt, Mark, and Hannes Mühleisen. 2019. “DuckDB: An Embeddable
Analytical Database.” *Proceedings of the 2019 ACM SIGMOD International
Conference on Management of Data*, 1981–84.
<https://doi.org/10.1145/3299869.3320212>.

The Apache Software Foundation. 2026. *Apache Iceberg Table Spec*.
Apache Iceberg documentation. <https://iceberg.apache.org/spec/>.

Thusoo, Ashish, Joydeep Sen Sarma, Namit Jain, et al. 2009. “Hive: A
Warehousing Solution over a Map-Reduce Framework.” *Proceedings of the
VLDB Endowment* 2 (2): 1626–29.
<https://doi.org/10.14778/1687553.1687609>.

Zeng, Xinyu, Yulong Hui, Jiahong Shen, Andrew Pavlo, Wes McKinney, and
Huanchen Zhang. 2023. “An Empirical Evaluation of Columnar Storage
Formats.” *Proceedings of the VLDB Endowment* 17 (2): 148–61.
<https://doi.org/10.14778/3626292.3626298>.
