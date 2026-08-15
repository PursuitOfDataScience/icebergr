# icebergr 0.1.0

First release. A deliberately narrow but correct subset of Apache Iceberg for R,
built on `iceberg-rust` 0.10.0 via `extendr`.

## Features

* Catalogs: `icebergr_catalog()` for REST catalogs, in-process `memory` catalogs
  (used for local warehouses and the bundled test fixture), and AWS Glue when
  the package is compiled with the optional `glue` Cargo feature.
* Discovery: `icebergr_list_namespaces()` and `icebergr_list_tables()`.
* Table handles: `icebergr_table()`, `icebergr_table_exists()`,
  `icebergr_schema()`, `icebergr_partitions()`, `icebergr_properties()`, and
  `icebergr_reload()` to re-read metadata so a handle can see a commit made by
  another session. `icebergr_schema(snapshot_id = )` reports the schema
  as it was at an earlier snapshot, which is also what `icebergr_scan()` resolves
  `filter` and `select` against when reading one: Iceberg keeps a schema per
  snapshot, so a column another engine has since renamed or dropped is still
  nameable as of the snapshot that had it.
* Reads: `icebergr_scan()` with predicate and projection pushdown, materialised
  with `icebergr_collect()` or `as.data.frame()`. Arrow is the interchange layer
  throughout, using the Arrow C stream interface, so no serialisation round trip
  occurs between Rust and R.
* Time travel: `icebergr_snapshots()` for snapshot history, and
  `icebergr_scan(snapshot_id = )` or `icebergr_scan(as_of = )` to read an
  earlier state of a table. `as_of` resolves against Iceberg's snapshot *log*,
  so a snapshot a rollback abandoned, or one that only ever existed on another
  branch, is not selected even though the snapshot list still carries it with a
  matching timestamp.
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
imply that this is an ASF-governed client, which it is not. See `inst/NOTICE`.

## Distribution

CRAN is the intended destination, and the build system is built for it:
vendored dependencies, offline builds, `-j2`, a confined `CARGO_HOME`, and a
per-crate `LICENSE.note`. CI exercises that exact submission path on every
commit.

Two open items before submitting, both now measured rather than estimated. A
default install compiles 308 crates and `vendor.tar.xz` weighs 31.3 MB, against a
largest-accepted precedent of 108 crates and 13.6 MB — so a size exemption
request is needed, and `cran-comments.md` makes it with the arithmetic shown. And
`iceberg-rust` 0.10.0 requires rustc 1.94 under a rolling MSRV; if CRAN's
machines are older, pinning 0.9.1 drops the requirement to 1.92 at the cost of
one API. See `FEASIBILITY.md` and the README's CRAN status section.
