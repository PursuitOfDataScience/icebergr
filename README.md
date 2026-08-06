<!-- README.md is generated from README.Rmd. Please edit that file -->


# icebergr

When an organisation's data moves into Apache Iceberg, R stops being a
first-class citizen and becomes the thing you export CSVs to.

**R is the only major data language without an Apache Iceberg client.** Apache
governs implementations in Java, Python (PyIceberg), Rust and Go. There is none
for R. Until now the only route was to read Iceberg tables through DuckDB as an
intermediary, which means no writes, no schema access, no snapshot management,
no catalog integration and no partition information.

Meanwhile Snowflake, Databricks, BigQuery, AWS and Dremio have all standardised
on Iceberg as the open table format. Parquet is well served in R by `arrow`, and
Delta Lake has a community Rust binding; Iceberg had nothing.

`icebergr` talks to Iceberg directly, through
[`iceberg-rust`](https://github.com/apache/iceberg-rust), the Apache-governed
Rust implementation, via `extendr`. Arrow is the interchange layer throughout, so
data crosses from Rust into R over the Arrow C stream interface without a
serialisation round trip.

## Installation

CRAN is the intended destination; `icebergr` is not there yet. See
[CRAN status](#cran-status) for what has to clear first. Until then, install from
GitHub.

```r
# install.packages("pak")
pak::pak("PursuitOfDataScience/iceberg")
```

Installing from source compiles Apache Iceberg's Rust implementation, so you need
a Rust toolchain (`rustc` >= 1.94):

```sh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

Expect the first build to take a while: the dependency tree is 343 crates.

Optional backends are off by default because each substantially enlarges that
tree:

```sh
# Object storage (S3)
ICEBERGR_CARGO_FEATURES=s3 R CMD INSTALL --preclean .

# AWS Glue catalog (implies s3)
ICEBERGR_CARGO_FEATURES=glue R CMD INSTALL --preclean .
```

## Getting started

Everything below runs offline against a locally generated table.

```r
library(icebergr)

tbl <- icebergr_example_table()
tbl
#> <icebergr_table>
#>   table:    db.events
#>   format:   v2
#>   snapshot: 4964299904926817223
#>   columns:  5
#>     id <int>
#>     event <string>
#>     amount <double>
#>     day <date>
#>     recorded_at <timestamptz>
```

Read it, pushing the filter and the projection down into the scan:

```r
icebergr_collect(
  icebergr_scan(tbl, filter = id > 1000 & amount > 900, select = c("id", "amount"))
)
```

Pushdown is the whole performance argument for Iceberg over reading raw Parquet,
so it is worth being able to *verify* rather than assume. `icebergr_scan_plan()`
shows which files a scan would touch, before reading any of them:

```r
nrow(icebergr_scan_plan(icebergr_scan(tbl)))
#> [1] 2
nrow(icebergr_scan_plan(icebergr_scan(tbl, filter = id > 1000)))
#> [1] 1
```

Travel back through snapshot history:

```r
history <- icebergr_snapshots(tbl)
history[, c("snapshot_id", "operation", "added_records")]

# The state before the most recent append
icebergr_collect(icebergr_scan(tbl, snapshot_id = history$snapshot_id[[1]]))

# Or by time
icebergr_collect(icebergr_scan(tbl, as_of = as.POSIXct("2024-06-01", tz = "UTC")))
```

Append new data:

```r
tbl <- icebergr_append(tbl, data.frame(
  id = 9001L,
  event = "purchase",
  amount = 42.5,
  day = as.Date("2024-07-01"),
  recorded_at = as.POSIXct("2024-07-01 09:00:00", tz = "UTC")
))
```

Connect to a real catalog. Credentials come from the environment, never from
arguments:

```r
Sys.setenv(ICEBERGR_REST_TOKEN = "...")
catalog <- icebergr_catalog("rest", uri = "https://catalog.example.com")

icebergr_list_namespaces(catalog)
icebergr_list_tables(catalog, "analytics")

tbl <- icebergr_table(catalog, "analytics.events")
icebergr_schema(tbl)
icebergr_partitions(tbl)
```

See `vignette("catalog-configuration")` for REST, Glue and S3 setup.

## Supported Iceberg features

Built against **`iceberg-rust` 0.10.0**. Reads and writes table spec **v1 and
v2**. v3 metadata is parsed, but v3-specific features are not exposed.

`icebergr_spec_support()` reports this matrix for your own build, resolved
against the optional features you compiled in.

✅ works &nbsp;·&nbsp; ⚙️ needs a build flag &nbsp;·&nbsp; 🦀 missing upstream in
`iceberg-rust` &nbsp;·&nbsp; 🚧 out of scope for 0.1.0

**📖 Reading**

| | |
| :-: | --- |
| ✅ | Read a table into Arrow / a tibble |
| ✅ | **Predicate pushdown** — filters prune whole files and row groups |
| ✅ | **Projection pushdown** — only selected columns leave disk |
| ✅ | Row group and row-level scan pruning |
| ✅ | Merge-on-read tables — positional *and* equality deletes applied |
| ✅ | Inspect the file plan before reading, with `icebergr_scan_plan()` |
| 🦀 | Row `limit` pushdown — `limit` bounds decoding, not planning |

**🕰️ Time travel**

| | |
| :-: | --- |
| ✅ | Snapshot history |
| ✅ | Read a snapshot by id |
| ✅ | Read as of a timestamp — resolved against snapshot history |

**✍️ Writing**

| | |
| :-: | --- |
| ✅ | Append rows |
| ✅ | Create a table (unpartitioned) and a namespace |
| ✅ | Register an existing table |
| 🦀 | Row-level deletes and `MERGE` / upsert — *reading* such tables works |
| 🚧 | Overwrite writes, partitioned table creation |

**🗂️ Catalogs and metadata**

| | |
| :-: | --- |
| ✅ | REST catalog |
| ✅ | In-process `memory` catalog, for local warehouses |
| ✅ | Schema and partition spec inspection |
| ⚙️ | AWS Glue — build with the `glue` Cargo feature |
| ⚙️ | Object storage (S3) — build with the `s3` Cargo feature |
| 🦀 | Hadoop / filesystem catalog — none exists upstream; use `type = "memory"` |

**🚧 Not in 0.1.0** — schema evolution, partition evolution, compaction and
maintenance, `dbplyr` lazy verbs, table encryption.

A correct narrow surface beats a broad buggy one. Anything marked 🦀 or 🚧 raises
an informative error rather than failing obscurely.

## Type fidelity

R types survive the Arrow round trip as follows:

| R type | Iceberg type | Round trip |
| --- | --- | --- |
| `integer` | `int` | Unchanged |
| `double` | `double` | Unchanged, including `Inf`, `-Inf` and `NaN` |
| `character` | `string` | Unchanged, UTF-8 preserved |
| `logical` | `boolean` | Unchanged |
| `Date` | `date` | Unchanged |
| `POSIXct` | `timestamptz` | Instant preserved; normalised to UTC |
| `bit64::integer64` | `long` | Unchanged, full 64-bit precision |
| `factor` | `string` | **Returns `character`.** Iceberg has no dictionary type, so levels cannot be carried. |

Snapshot ids are **character**, not numeric. Iceberg assigns them as random
64-bit integers and an R numeric holds only 53 bits, so a double round trip would
silently select the wrong snapshot.

## CRAN status

**CRAN is the target.** The package is built to submit: `configure` and
`configure.win`, `Makevars.in` templates, vendored dependencies via
`tools/vendor.R`, an offline `--offline` build, `-j2` to stay inside CRAN's
parallelism limit, a `CARGO_HOME` confined to the build tree, and a per-crate
`LICENSE.note` inventory. CI runs that exact path on every commit, so the
submission build is exercised continuously rather than assembled at the last
minute.

Two things have to clear first. Both are tractable; neither is settled.

**1. Vendored size.** `iceberg` pulls **343 crates** before any optional catalog,
and `[features] default = []` is already empty — `tokio`, `reqwest`, `parquet`,
eight `arrow-*` crates and `apache-avro` are unconditional, so feature flags
cannot trim them. For scale, the largest vendored Rust package CRAN has accepted
is `arcgisgeocode` at 108 crates and 13.6 MB, itself an approved exception to the
10 MB guideline — and that guideline explicitly allows requesting more.

What is being done about it: `tools/vendor.R` prunes tests, examples, benchmarks
and fixtures from the vendor tree while preserving every licence file, and the CI
job reports the resulting size on each run. That measurement is what a size
exemption request has to be built on, so the number matters more than any
estimate.

**2. Minimum Rust version.** `iceberg-rust` 0.10.0 needs `rustc` 1.94 and edition
2024, and bumps its minimum most releases. Whether CRAN's build machines have
1.94 needs confirming against CRAN directly rather than assumed.

If they do not, pinning an earlier `iceberg-rust` is a real fallback, and the cost
is small:

| `iceberg-rust` | MSRV | Cost of pinning it |
| --- | --- | --- |
| 0.10.0 (current) | 1.94 | — |
| 0.9.1 | 1.92 | Loses `with_runtime`; the runtime is then inherited from the calling context, which is where we already are |
| 0.8.0 | 1.88 | Predates the storage-factory refactor; needs real binding changes |

Edition 2024 itself only needs 1.85, which is early 2025, so the edition is not
the constraint — the rolling minimum is.

**Precedent worth knowing.** `polars` was on CRAN in 2023 with a non-vendored,
network-fetching build that current policy disallows, and is on r-universe today.
That is a caution about *how* a heavy Rust package fails a submission, not proof
that one must.

`FEASIBILITY.md` has the full analysis, the measurements behind these numbers, and
what remains unverified.

## Licence

GPL (>= 3). Bundled Rust crates keep their own licences, listed in `NOTICE` and
`LICENSE.note`.

Apache, Apache Iceberg and Iceberg are trademarks of The Apache Software
Foundation. `icebergr` is an independent community package, not affiliated with
or endorsed by the ASF, and is not one of the official Iceberg clients.
