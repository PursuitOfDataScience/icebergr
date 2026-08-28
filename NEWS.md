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
  occurs between Rust and R. `long` columns come back as `bit64::integer64` at
  any depth, including inside a `struct`, so a value past 2^53 stays exact.
  A filter on a `decimal` column runs with `iceberg-rust`'s row-level selection
  disabled, since in 0.10.0 that stage discards every row of an ordering
  comparison against a decimal; file and row group pruning still apply.
  `case_sensitive = FALSE` prefers an exact match, so a table holding both `id`
  and `ID` resolves each to itself, and a name matching two columns and neither
  exactly is an error rather than a silent choice.
* Time travel: `icebergr_snapshots()` for snapshot history, and
  `icebergr_scan(snapshot_id = )` or `icebergr_scan(as_of = )` to read an
  earlier state of a table. `as_of` resolves against Iceberg's snapshot *log*,
  so a snapshot a rollback abandoned, or one that only ever existed on another
  branch, is not selected even though the snapshot list still carries it with a
  matching timestamp.
* Append-only writes: `icebergr_append()`, to an unpartitioned table whose
  metadata file is named the way Iceberg names them. Both of those are checked
  before any data file is written, because Iceberg only discovers them at the
  commit — which would leave orphan Parquet in the warehouse and report the cause
  in terms of neither the table nor the file.
* Nested types: `struct` and `list` columns read and write, a `struct` arriving as
  a data frame column. Iceberg cannot push a filter or a projection down *onto* a
  nested field, so read the parent column and subset it in R. Nanosecond
  timestamps read, write and filter, but an R `POSIXct` is a double of seconds, so
  sub-microsecond precision is lost.
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

Installing from source compiles Apache Iceberg's Rust implementation, so a Rust
toolchain is required: `rustc` 1.92 or newer. `iceberg-rust` 0.10.0 declares
1.94, but nothing in the tree uses a feature newer than 1.92, so cargo is passed
`--ignore-rust-version` and `configure` gates on the version the package is
actually tested against.
The Rust dependencies a default install compiles are vendored in
`src/rust/vendor.tar.xz`, so that install never touches the network; it compiles
264 crates and takes a while the first time. CI exercises that exact offline path
on every commit. The optional `s3` and `glue` features are the exception: they
draw in about a hundred further crates, which would have tripled the source
tarball, so enabling one of them resolves those from crates.io and needs network
access.
