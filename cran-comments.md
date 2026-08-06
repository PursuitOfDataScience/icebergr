# cran-comments.md

Draft for the eventual submission. Two items below need the measured figures from
CI substituted in before sending, and one needs confirming with CRAN first — all
three are marked TODO.

## Test environments

- local: TODO (platform, R version)
- GitHub Actions: ubuntu-latest (R release, R oldrel-1), macos-latest (R release),
  windows-latest (R release)
- GitHub Actions: vendored offline build reproducing the CRAN build path

## R CMD check results

TODO: substitute actual results.

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
- `NOTICE` carries the Apache-2.0 attribution and trademark notice for the
  bundled Apache Iceberg Rust code.

**The tarball exceeds the 10 MB guidance, and I would like to request an
increased limit.** TODO: state the measured size from the `check-vendored` CI job.

The reason is not incidental. Apache Iceberg's data path is Arrow and Parquet, so
the `iceberg` crate depends unconditionally on eight `arrow-*` crates, `parquet`,
`apache-avro` (Iceberg manifests are Avro), `tokio` and `reqwest`. Its
`[features] default = []` is already empty, so there is no feature configuration
that removes them — the vendored floor is 343 crates for the core functionality
alone. Optional catalogs that would enlarge it further (AWS Glue, S3 object
storage) are deliberately behind non-default Cargo features and are *not* built
in a default install.

To keep the archive as small as possible, `tools/vendor.R` strips tests,
examples, benchmarks, fuzz targets, CI configuration and test fixtures from the
vendor tree before compressing, while preserving every licence and notice file so
attribution remains complete.

I recognise this is larger than is usual. I would rather ask than ship something
that does not comply, and I am happy to adjust the scope if the size is not
acceptable.

### Rust version

TODO — confirm with CRAN before submitting: does the build farm carry
`rustc` >= 1.94?

`iceberg-rust` 0.10.0 requires 1.94 and Rust edition 2024 (which itself needs
only 1.85). If 1.94 is not available, I can pin `iceberg-rust` 0.9.1 instead,
which requires 1.92 and costs one API that the package does not depend on
essentially. Please tell me which version to target and I will pin accordingly.

`configure` fails early with an explicit message naming the required and
installed versions if the toolchain is too old, rather than failing partway
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
Foundation. The package is named `icebergr`, not `iceberg`, and `NOTICE`,
`DESCRIPTION` and the documentation each state that this is an independent
community package with no ASF affiliation or endorsement. Uses of the mark in the
Title and Description are nominative — identifying the format the package reads
and writes.

TODO before submitting: contact `trademarks@apache.org` about the name and retain
the response.

## Downstream dependencies

None; this is a new package.
