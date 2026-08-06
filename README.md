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

`icebergr` is **not on CRAN**, and cannot be today. See
[Why not CRAN](#why-not-cran).

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

| Feature | Status |
| --- | --- |
| Read table into Arrow / tibble | Supported |
| Predicate pushdown | Supported |
| Projection pushdown | Supported |
| Row group and row-level scan pruning | Supported |
| Reading merge-on-read tables (positional and equality deletes applied) | Supported |
| Snapshot time travel (`snapshot_id`) | Supported |
| Timestamp time travel (`as_of`) | Supported, resolved in R against snapshot history |
| Snapshot history | Supported |
| Append-only writes | Supported |
| Create table (unpartitioned) | Supported |
| Create namespace | Supported |
| Register an existing table | Supported |
| Schema and partition spec inspection | Supported |
| REST catalog | Supported |
| In-process `memory` catalog | Supported |
| AWS Glue catalog | Optional, needs the `glue` Cargo feature |
| Object storage (S3) | Optional, needs the `s3` Cargo feature |

Not supported, and why the distinction matters — some of these are absent
upstream, others are simply out of scope here:

| Feature | Why not |
| --- | --- |
| Hadoop / filesystem catalog | **Not implemented in `iceberg-rust`.** Use `type = "memory"` with a warehouse directory. |
| Row limit pushdown | **Not in `iceberg-rust`'s scan API.** `limit` is applied as batches arrive, so it bounds decoding but not planning. |
| Row-level deletes (writing) | **Not implemented in `iceberg-rust`.** Copy-on-write and merge-on-read *writes* are an open upstream epic. Reading such tables works. |
| MERGE / upsert | **Not implemented in `iceberg-rust`.** |
| Overwrite writes | Out of scope for 0.1.0 |
| Schema evolution | Out of scope for 0.1.0 |
| Partitioned table creation | Out of scope for 0.1.0 |
| Partition evolution | Out of scope for 0.1.0 |
| Compaction and maintenance | Out of scope for 0.1.0 |
| `dbplyr` lazy verbs | Out of scope for 0.1.0 |
| Table encryption | Not exposed in 0.1.0 |

A correct narrow surface beats a broad buggy one. Anything listed as unsupported
raises an informative error rather than failing obscurely.

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

## Why not CRAN

CRAN permits Rust, but requires vendored dependencies, an offline build and
authorship records for every bundled crate. Two things make that unreachable
here:

- **Dependency weight.** `iceberg` alone pulls **343 crates** before any optional
  catalog, and `[features] default = []` is already empty, so there is nothing to
  trim: `tokio`, `reqwest`, `parquet`, eight `arrow-*` crates and `apache-avro`
  are all unconditional. For comparison, the largest vendored Rust package CRAN
  has accepted is `arcgisgeocode` at 108 crates and a 13.6 MB `vendor.tar.xz`,
  itself an approved exception to the 10 MB guideline.
- **A rolling MSRV.** `iceberg-rust` requires `rustc` 1.94 and edition 2024, and
  bumps its minimum with every release. CRAN's build machines run
  distribution-packaged toolchains that lag well behind.

The nearest precedent points the same way: `polars` was on CRAN in 2023 with a
non-vendored, network-fetching build that current policy disallows, and is
distributed via r-universe today.

The package nonetheless ships a CRAN-shaped build system — `configure`,
`Makevars.in`, vendored offline builds, `-j2`, a confined `CARGO_HOME` — so
submission stays possible if the situation changes. `FEASIBILITY.md` has the full
analysis and the measurements behind it.

## Licence

GPL (>= 3). `iceberg-rust` is Apache-2.0, which permits inclusion in a GPL-3
work; the combined work is GPL (>= 3). Apache-2.0 is *not* compatible with
GPL-2.0, which is why this is GPL (>= 3) and not GPL (>= 2). See `NOTICE` and,
after packaging, `LICENSE.note` for the per-crate inventory.

Apache, Apache Iceberg and Iceberg are trademarks of The Apache Software
Foundation. `icebergr` is an independent community package, not affiliated with,
sponsored by or endorsed by the ASF, and is not one of the official Iceberg
clients.
