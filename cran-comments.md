# cran-comments.md

## Test environments

- Local: CentOS Linux 8 (x86_64), R 4.6.0, rustc 1.97.1 — vendored, offline
  build, the same path a CRAN build takes.
- GitHub Actions: ubuntu-latest (R release and R oldrel-1), macos-latest
  (R release), windows-latest (R release), building against crates.io.
- GitHub Actions: a separate job that vendors every dependency and then builds
  with no network access at all, reproducing the CRAN build path and measuring
  the resulting tarball.

## R CMD check results

0 errors | 0 warnings | 1 note

The note is CRAN incoming feasibility: a new submission, and the size of the
tarball. The size is the subject of the request below.

Check also reports, as INFO rather than a note, an installed size of 24.0 Mb, all
of it `libs`. That is the statically linked Rust library: Apache Iceberg's Rust
implementation, the Arrow and Parquet columnar readers, and an Avro reader for
Iceberg manifests.

## This is a new submission

`icebergr` is a client for Apache Iceberg, the open table format. R has
previously been able to read Iceberg tables only by routing through DuckDB as an
intermediary, which precludes writes, schema access, snapshot management and
catalog integration. The package binds `iceberg-rust`, the Apache-governed Rust
implementation, via `extendr`.

## Notes for the reviewer

### Rust is required, and the vendored sources are large

`SystemRequirements` declares `Cargo (Rust's package manager), rustc >= 1.94, xz`.

The package follows "Using Rust in CRAN packages" in full:

- All Rust dependencies are vendored in `src/rust/vendor.tar.xz`, compressed with
  xz.
- The build never accesses the network. `configure` passes `--offline` to cargo
  whenever the vendored archive is present and `NOT_CRAN` is unset.
- Cargo's parallelism is pinned with `-j 2`, since it would otherwise default to
  the number of logical CPUs.
- `CARGO_HOME` is confined to the build directory and removed afterwards.
- Authorship, repository and licence for every vendored crate are recorded in
  `LICENSE.note`, generated from the vendor tree itself so the inventory
  describes exactly what ships.
- `inst/NOTICE` carries the Apache-2.0 attribution and trademark notice for the
  bundled Apache Iceberg Rust code.

**The tarball exceeds the 10 MB guidance, and I would like to request an
increased limit.** Measured from the vendored offline build:

| | |
| --- | --- |
| Crates compiled by a default install | 308 |
| Crates present in `vendor.tar.xz` | 442 |
| `src/rust/vendor.tar.xz` | 31.3 MB |

The reason is not incidental. Apache Iceberg's data path is Arrow and Parquet, so
the `iceberg` crate depends unconditionally on eight `arrow-*` crates, `parquet`,
`apache-avro` (Iceberg manifests are Avro), `tokio` and `reqwest`. Its
`[features] default = []` is already empty, so no feature configuration removes
them.

Two things I checked before asking, in case they are the first questions:

- **Why vendor 442 crates to build 308?** The extra 134 are the optional AWS Glue
  and S3 backends, which are behind non-default Cargo features and are not
  compiled by a default install. They still have to be *vendored*, because cargo
  resolves the whole lock graph before it selects features, and an offline build
  fails at resolution if any locked package is absent from the vendor directory.
  The consolation is that a user who wants those backends can enable them from
  the CRAN tarball without any network access at all.
- **Would dropping those optional backends help?** Measured: it takes the archive
  from 31.3 MB to 28 MB. The AWS and `windows-sys` trees are largely generated
  code and compress extremely well, so removing 87 MB of uncompressed sources
  buys 3 MB of tarball. It is not the lever it looks like, so I have kept the
  functionality rather than trade it for 10%.

To keep the archive as small as possible, `tools/vendor.R` strips tests,
examples, benchmarks, fuzz targets, CI configuration and test fixtures from the
vendor tree before compressing (27 MB of the uncompressed tree), while preserving
every licence and notice file so attribution remains complete.

I recognise this is well beyond what is usual, and beyond the largest exception I
am aware of having been granted. I would rather ask than ship something that does
not comply. If the size is not acceptable I am happy to hear what would be, and
to withdraw rather than press the point.

### Rust version

`iceberg-rust` 0.10.0 requires rustc 1.94 and Rust edition 2024 (the edition
itself needs only 1.85). Upstream operates a rolling MSRV.

If the build farm carries an older toolchain, please say which version and I will
pin accordingly: `iceberg-rust` 0.9.1 lowers the requirement to 1.92 and costs
only `CatalogBuilder::with_runtime`, which this package can do without.

`configure` fails early with an explicit message naming both the required and the
installed version if the toolchain is too old, rather than failing partway
through a compile.

### Examples, tests and vignettes are fully offline

No example, test or vignette contacts a network service, a catalog server, or
requires credentials. `icebergr_example_table()` builds a real Iceberg table in
`tempdir()` using the in-process `memory` catalog on the local filesystem, and
everything else runs against that.

The table is generated rather than shipped in `inst/` because Iceberg records
absolute paths in its table metadata and inside its Avro manifests, so a
pre-built table would not resolve once installed to a different location.

### Credentials

Credentials for remote catalogs are read only from environment variables. They
are never accepted as function arguments, never printed by any `print()` method,
and error messages report configuration *keys* only, never values.

### Trademark

Apache, Apache Iceberg and Iceberg are trademarks of The Apache Software
Foundation. The package is named `icebergr`, not `iceberg`, and `inst/NOTICE`,
`DESCRIPTION` and the documentation each state that this is an independent
community package with no ASF affiliation or endorsement. Uses of the mark in the
Title and Description are nominative — identifying the format the package reads
and writes.

## Downstream dependencies

None; this is a new package.
