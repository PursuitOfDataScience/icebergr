# icebergr 0.1.0

First release. A deliberately narrow but correct subset of Apache Iceberg for R,
built on `iceberg-rust` 0.10.0 via `extendr`.

## Features

* Catalogs: `icebergr_catalog()` for REST catalogs, in-process `memory` catalogs
  (used for local warehouses and the bundled test fixture), and AWS Glue when
  the package is compiled with the optional `glue` Cargo feature.
* Discovery: `icebergr_list_namespaces()` and `icebergr_list_tables()`.
* Table handles: `icebergr_table()`, `icebergr_schema()`,
  `icebergr_partitions()`.
* Reads: `icebergr_scan()` with predicate and projection pushdown, materialised
  with `icebergr_collect()` or `as.data.frame()`. Arrow is the interchange layer
  throughout, using the Arrow C stream interface, so no serialisation round trip
  occurs between Rust and R.
* Time travel: `icebergr_snapshots()` for snapshot history, and
  `icebergr_scan(snapshot_id = )` or `icebergr_scan(as_of = )` to read an
  earlier state of a table.
* Append-only writes: `icebergr_append()`.
* `icebergr_spec_support()` reports the supported Iceberg spec version and the
  full supported/unsupported feature matrix programmatically.

## Deliberately not included

Row-level deletes, MERGE/upsert, full schema evolution, partition evolution,
compaction and maintenance operations, and a `dbplyr` backend. Several of these
are also absent from `iceberg-rust` itself; see `icebergr_spec_support()` and
the README for which is which.

## Naming

The package is named `icebergr`, not `iceberg`. Apache Software Foundation
trademark policy does not permit third parties to use Apache marks as the
primary branding of their own products, and a bare `iceberg` package would also
imply that this is an ASF-governed client, which it is not. See the NOTICE file.

## Distribution

CRAN is the intended destination, and the build system is built for it:
vendored dependencies, offline builds, `-j2`, a confined `CARGO_HOME`, and a
per-crate `LICENSE.note`. CI exercises that exact submission path on every
commit.

Two open items before submitting. The vendored tree is 343 crates before any
optional catalog, against a largest-accepted precedent of 108 crates and 13.6 MB
— so a size exemption request will be needed, and `tools/vendor.R` reports the
measured figure it would rest on. And `iceberg-rust` 0.10.0 requires rustc 1.94
under a rolling MSRV; if CRAN's machines are older, pinning 0.9.1 drops the
requirement to 1.92 at the cost of one API. See `FEASIBILITY.md` and the README's
CRAN status section.
