# icebergr 0.2.0

`iceberg-rust` is unmoved at 0.10.0, and no function was gained or lost. This
release fixes an append that could leave a table unreadable, filters that
returned the wrong rows without saying so, and a hang in forked workers, and it
stops handing credentials to things that should not have them.

## Bug fixes

* **`icebergr_append(properties =)` could make a table unreadable.** A property
  named `operation` was written as a second `"operation"` key in the table's
  metadata, after which no engine could load, register or append to the table
  again. Iceberg's own summary metrics were open to it too: a `deleted-records`
  property was subtracted into `total-records`. Every key Iceberg writes into a
  snapshot summary itself is now refused, and so is a name given twice.
* **A timestamp filter was a microsecond out.** Fractional seconds were
  truncated rather than rounded, and the double R holds for a microsecond
  timestamp is often just below it, so `ts == x`, with `x` read back from the
  same table, found no row for most values, and `>=` or `<` moved the boundary.
* **A `POSIXlt` filter value or `as_of` was read in the wrong zone.** Its
  wall-clock fields were taken as UTC, so a time from
  `strptime(..., tz = "America/New_York")` filtered or travelled four or five
  hours away from the instant it named.
* **A filter now keeps the rows R would, where `NA` and `NaN` are concerned.**
  It was handed to Iceberg with Iceberg's semantics, which differ from R's in
  four ways. `x > 1` matched `NaN`, and only in files the scan read, since file
  statistics leave `NaN` out: of two identical `NaN` rows, one could come back
  and the other not. `is.na(x)` missed `NaN`. `x == 0` missed a stored `-0`.
  And `!(x %in% c(1, 2))` dropped the rows where `x` is `NA`, which R keeps
  because `%in%` is never `NA`. Checked against R's own evaluation of 3,200
  random filters over columns holding all of these. String ordering still
  follows Iceberg's byte order, which is R's only in the C locale.
* **A column on the value side of a filter was read as a local variable.**
  `filter = a > b`, with `b` a column, compared `a` against whatever local `b`
  was in scope, silently. An Iceberg predicate cannot compare two columns, so
  this is now an error that says so.
* **A forked worker hung forever.** After any icebergr call in the parent, the
  first call in a `parallel::mclapply()` worker waited on runtime threads that
  do not survive `fork()`, with no error, and neither Ctrl-C nor the timeout
  could end it. It now fails at once and points at `parallel::makeCluster()`.
* **A data frame naming a column twice lost the second one** on append. It is
  now refused.
* `icebergr_register_table()` accepts an object-storage location such as
  `s3://...`, which it used to refuse as a missing file, and no longer refuses
  every registration on a REST catalog whose `warehouse` is a name rather than
  a directory.
* A catalog property given as a number or a logical reaches `iceberg-rust` in
  the form it parses: `1e5` as `"100000"` rather than `"1e+05"`, and `TRUE` as
  `"true"`. A property passed twice through `...` is refused rather than
  silently keeping the last.
* An `S3://` warehouse is object storage whatever the case of its scheme, as it
  already was for forwarding credentials; it used to be put on the local disk.
* The cleartext check recognises `http://LOCALHOST` and the rest of
  127.0.0.0/8 as loopback, and counts a `header.Authorization`,
  `header.Cookie` or `header.X-Api-Key` property as a credential.
* `batch_size = 0` is refused rather than read as the default.
* A large append no longer runs under a single timeout. Rows reach the Parquet
  writer in slices, each its own call, so the five-minute ceiling bounds one
  slice rather than the whole upload. The files written are byte-identical.
* `icebergr_snapshots()` orders a v1 table's snapshots the same way on every
  call, and its `summary` JSON lists keys in sorted rather than hash order.
* An interrupt or a timeout while reading a batch is reported as such, rather
  than as "the Iceberg scan panicked".

## Credentials and robustness

Closing the review findings tracked in
[#2](https://github.com/PursuitOfDataScience/icebergr/issues/2).

* **A credential is no longer sent over an unencrypted connection.** An
  `http://` `uri`, or OAuth2 endpoint, is now an error when any credential
  property is populated, rather than putting `Authorization: Bearer ...` on the
  wire in the clear. A loopback address is exempt; set
  `ICEBERGR_ALLOW_INSECURE_CREDENTIALS=true` to override.
* **Ambient `AWS_*` credentials are forwarded only to object storage.** They
  were previously added to every catalog regardless of type, so a third-party
  REST catalog, which controls each table's `location` and can return its own
  `s3.endpoint`, could have the client sign requests to a host it chose using
  the user's keys. They now require `storage = "s3"`, `type = "glue"`, or an
  `s3://` warehouse. The explicit `ICEBERGR_S3_*` variables are unaffected.
* **`icebergr_register_table()` gains `confine`, defaulting to `TRUE`.** A
  metadata file names absolute paths for its `location`, manifests and data
  files, so registering one from an untrusted source read whatever it
  nominated, and with the `s3` feature compiled in it could make an outbound
  request from a nominally offline `memory` catalog. The file must now sit
  inside the catalog's warehouse; pass `confine = FALSE` for the previous
  behaviour.
* An error carrying an upstream message no longer leaks a credential the
  upstream echoed: `user:password@` in a URL, and the value of a secret query
  or form parameter such as `client_secret` or `X-Amz-Signature`, are redacted.
  The module already promised this and only delivered it for the key list.
* `print()` on a catalog redacts `user:password@` in its `uri`.
* **Every await now has a five-minute ceiling.** A catalog that accepted the
  connection and never answered used to wedge the session permanently, since
  `block_on` parks R's thread and Ctrl-C is only checked between evaluations.
  `ICEBERGR_TIMEOUT_SECONDS` changes it; `0` disables it. The ceiling is per
  request, per record batch or per slice of an append, so a long scan or a large
  write is not truncated.
* `ICEBERGR_WORKER_THREADS` is clamped to 64. It had no upper bound, so a typo
  spawned threads until the allocator gave up.
* `icebergr_scan_plan()` drains the plan into its five output columns as tasks
  arrive, rather than collecting every `FileScanTask` and then walking the
  collection five times. One row per task is inherent, but a task carries its
  schema, its predicate and its delete-file list, none of which this function
  returns, so holding all of them alongside the columns was avoidable.
* **Ctrl-C now interrupts a blocking catalog or storage call.** `block_on` parks
  R's own thread and R only tests its interrupt flag between evaluations, so an
  interrupt used to do nothing at all until the call finished. The future is now
  polled in 200 ms slices, and between slices, back on R's thread and outside
  the runtime, R's flag is read and turned into an ordinary error. The timeout
  above remains the backstop for where Ctrl-C cannot reach, such as a
  non-interactive session. Closes
  [#12](https://github.com/PursuitOfDataScience/icebergr/issues/12).
* **An interrupt or a timeout now reports itself as a plain R error.** Both are
  raised from Rust as panics, because the value they have to abandon is the
  future's own type and there is nothing to return in its place, and a panic
  prints a banner naming a source line and offering a backtrace before extendr
  converts it. Pressing Ctrl-C should not look like a crash, so the panic hook
  recognises this package's own deliberate aborts and stays quiet for them. A
  genuine bug, such as an index out of bounds or an `unwrap()` on `NULL`, still
  prints in full.

## Documentation

* `?icebergr_catalog` now says that a REST or Glue handle does not contact the
  server: `iceberg-rust` connects on the first operation that needs it, so a
  mistyped `uri`, an unreachable host or an unset credential all return a handle
  and fail later, at `icebergr_list_namespaces()` or `icebergr_table()`. The
  troubleshooting section of `vignette("catalog-configuration")` gained the same
  note, since the symptom reads as a fault in those functions.
* Corrections that were wrong in 0.1.0 or in this release's drafts:
  `vignette("catalog-configuration")` gave `glue.region` as the Glue region
  property, where the Glue client reads `region_name`, and showed SigV4 settings
  for a REST catalog that `iceberg-rust` 0.10.0 does not support and silently
  ignores. `vignette("time-travel")` said a rollback removes a snapshot-log
  entry (it adds one) and that `iceberg-rust` lacks snapshot expiry (it lacks
  rollback). The description no longer says that going through DuckDB rules out
  writes, which DuckDB has supported for REST catalogs since 1.4.
* Seven vignettes, up from two. `table-format` explains what a table format is
  as distinct from a file format, and what the Hive directory convention could
  not do; `pushdown` shows the three levels a filter acts at and how to confirm
  each with `icebergr_scan_plan()` rather than assume it; `time-travel` covers
  snapshot history and the two ways `as_of` is easy to misread; `writing` covers
  appends, creation and registration, and why the operations it cannot do are
  refused before anything reaches the warehouse; `types` covers the R, Arrow and
  Iceberg correspondence and the five cases that need care. Each carries a
  bibliography.
* `icebergr_create_table()`'s behaviour is now documented rather than implied:
  it reads a schema off the data frame and writes **no rows**, leaving a table
  with no snapshot at all.
* A `pkgdown` site at <https://pursuitofdatascience.github.io/icebergr/>.
* A package logo, generated by `data-raw/logo.R`.
* A much shorter README, with the packaging analysis it used to carry left in
  `FEASIBILITY.md`, where it was already duplicated.

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
  commit, which would leave orphan Parquet in the warehouse and report the cause
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
