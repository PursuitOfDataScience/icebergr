# cran-comments.md

## This is a resubmission

The previous submission (0.1.0, 2026-08-27) was rejected by the incoming
pre-tests with 1 ERROR on r-devel-windows-x86_64: installation failed because
`configure` refused a toolchain below rustc 1.94. The Debian flavour installed
and checked cleanly, so the failure was specific to the Windows farm's rustc
1.92.0.

Thank you for running it — that was the one input I said in the previous
submission I had been unable to measure, and it turned out that the required
version was wrong rather than the toolchain being too old.

Changes in this version:

* **The declared minimum Rust version is now 1.92, and the package builds on it.**
  `SystemRequirements` reads `rustc >= 1.92`. The 1.94 in the previous submission
  came from four crates in the tree declaring `rust-version = "1.94"` under
  `iceberg-rust`'s rolling-MSRV policy; none of them uses a language or library
  feature newer than 1.92. Verified by building the full vendored tree offline
  with rustc 1.92.0 and running the whole check suite against it — see "Rust
  version" below. No dependency was downgraded and no functionality was dropped.
* `src/Makevars` and `src/Makevars.win` pass `--ignore-rust-version` to cargo,
  since cargo rejects a build outright when a *dependency* declares more than the
  active toolchain. `tools/msrv.R` remains the gate on the real floor, so a
  genuinely too-old toolchain still fails at `configure` with a readable message.
* Reworded the Description to remove the three words the pre-test flagged as
  possibly misspelled. `README` is now quoted; "schemas" and "pushdown" are gone
  in favour of wording that is not jargon.

The tarball size is unchanged, and the request about it below stands.

## Test environments

- Local: CentOS Linux 8 (x86_64), R 4.6.0, rustc 1.97.1 — vendored, offline
  build, the same path a CRAN build takes.
- Local: the same machine and R, with **rustc 1.92.0** — the version the Windows
  farm reported — again vendored and offline. Added for this resubmission.
- GitHub Actions: ubuntu-latest (R release and R oldrel-1), macos-latest
  (R release), windows-latest (R release), building against crates.io.
- GitHub Actions: a separate job that vendors every dependency and then builds
  with no network access at all, reproducing the CRAN build path and measuring
  the resulting tarball.
- GitHub Actions: a new job for this resubmission that reads the floor out of
  `SystemRequirements` and type-checks the whole tree on exactly that toolchain,
  so the declared minimum cannot drift again without CI going red. On this
  submission it installed rustc 1.92.0 and processed all 264 crates of the
  default graph with no warnings. Every job above passed on the submitted tree,
  windows-latest included.

## R CMD check results

0 errors | 0 warnings | 1 note

The note is CRAN incoming feasibility: a new submission, and the size of the
tarball. The size is the subject of the request below.

Two warnings and two further notes appear on the local machine only, and none is
a property of the package — each is a tool that is simply not installed there.
`checking top-level files` wants `checkbashisms` (the package's own shell scripts
are `configure` and `configure.win`, both two lines and both POSIX);
`checking HTML version of manual` wants `tidy`; and with no `pdflatex` on the
machine, `checking PDF version of manual without index` fails outright and leaves
an `icebergr-manual.tex` behind, which then raises `non-standard things in the
check directory`. Passing `--no-manual` removes all of the LaTeX ones. The
GitHub Actions runners have the full set, and the numbers above are from there.

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

`SystemRequirements` declares `Cargo (Rust's package manager), rustc >= 1.92, xz`.

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
- Every one of those 442 crates is under a permissive licence, and none states no
  licence at all: MIT, Apache-2.0, BSD-2/3-Clause, ISC, Zlib, 0BSD, Unlicense,
  CC0-1.0, MIT-0, BSL-1.0, Unicode-3.0, Apache-2.0 WITH LLVM-exception, and
  CDLA-Permissive-2.0 for one crate that carries CA root *data* rather than code.
  Nothing bundled is copyleft. Apache-2.0 is the strictest of the set, and it is
  the reason the package is GPL (>= 3) rather than GPL (>= 2); see `inst/NOTICE`.
- `inst/NOTICE` carries the Apache-2.0 attribution and trademark notice for the
  bundled Apache Iceberg Rust code.

**The tarball exceeds the 10 MB guidance, and I would like to request an
increased limit.** Measured from the vendored offline build:

| | |
| --- | --- |
| Crates a default install actually compiles | 264 |
| Crates in the default dependency graph, all platforms | 308 |
| Crates present in `vendor.tar.xz` | 442 |
| `src/rust/vendor.tar.xz` | 31.3 MB |

The reason is not incidental. Apache Iceberg's data path is Arrow and Parquet, so
the `iceberg` crate depends unconditionally on eight `arrow-*` crates, `parquet`,
`apache-avro` (Iceberg manifests are Avro), `tokio` and `reqwest`. Its
`[features] default = []` is already empty, so no feature configuration removes
them.

Two things I checked before asking, in case they are the first questions:

- **Why vendor 442 crates to compile 264?** Three layers, each forced by cargo
  rather than chosen. 44 belong to other operating systems — `windows-sys`,
  `wasi`, `redox` — and never build on any one machine, which is the difference
  between the 264 compiled here and the 308 in the all-platform default graph.
  Another 110 are the optional AWS Glue and S3 backends, behind non-default Cargo
  features, taking the all-platform graph to 418. The remaining 24 are in
  `Cargo.lock` without appearing in any resolved graph. None of the three can be
  pruned, because cargo resolves the whole lock graph before it selects features
  or filters targets, and an offline build fails at resolution if any locked
  package is absent from the vendor directory. The consolation is that a user who
  wants those backends can enable them from the CRAN tarball with no network
  access at all.

  Counts reproducible with `cargo tree -e normal,build --prefix none` (add
  `--target all` for the all-platform figures, `--features glue` for the optional
  backends), and the 264 by counting `Compiling` lines in a fresh offline install.
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

`SystemRequirements` declares rustc >= 1.92. That is a measured floor: the
complete vendored tree was built offline with rustc 1.92.0 (the version
`00install.out` reported from the Windows farm), and `R CMD check --as-cran` was
run against the result.

What went wrong last time is worth stating precisely, because the number I
declared was not a compiler requirement at all. Four crates in the tree declare
`rust-version = "1.94"` — `iceberg`, `iceberg-catalog-rest`,
`iceberg-catalog-glue` and `fastnum` — under `iceberg-rust`'s rolling-MSRV
policy, which bumps the declaration on most releases whether or not the code
needs it. Nothing else in the tree exceeds 1.91.1. None of those four uses a
language or library feature newer than 1.92. Edition 2024 itself needs only 1.85.

Two things carry that measurement over to Windows, which I have no 1.92 Windows
machine to check directly. None of the four contains any Windows-specific code —
no `cfg(windows)` or `cfg(target_os = "windows")` anywhere in their sources — so
they have no platform-gated path that a Linux build would have skipped. And of
the crates that *do* carry Windows-specific code, not one declares a floor above
1.91.1 — the highest are `aws-config`, `aws-runtime` and `aws-smithy-http-client`
— so nothing on the Windows-only side of the tree claims to need more than 1.92
either.

Cargo, however, treats a *dependency's* `rust-version` as a hard error rather
than a warning:

    error: rustc 1.92.0 is not supported by the following packages:
      fastnum@0.7.5 requires rustc 1.94
      iceberg@0.10.0 requires rustc 1.94
      iceberg-catalog-rest@0.10.0 requires rustc 1.94

so the build stops at resolution, before rustc ever sees the code. `src/Makevars`
and `src/Makevars.win` therefore pass `--ignore-rust-version`, which is cargo's
documented opt-in for precisely this case and has been respected since Cargo
1.56, the same release that began enforcing the field — so no toolchain can
enforce the declaration without also accepting the flag. The declarations
themselves are left exactly as upstream ships them: the vendored sources are
unmodified, and `tools/vendor.R` needs no patch step.

That leaves `tools/msrv.R`, run from `configure`, as the single version gate. It
reads the floor from `SystemRequirements` so `DESCRIPTION` stays the source of
truth, and fails early with a message naming both the required and the installed
version rather than failing partway through a compile. The trade is deliberate:
the gate is now a floor the package has actually been checked against instead of
one inherited from an upstream policy, and `DEVELOPMENT.md` records that it may
only be raised after building and testing on the new value.

The optional backends were checked on the same floor, not just the default
build: `cargo check --features glue` (which adds the AWS SDK and opendal, around
517 crates in total, and includes the fourth 1.94-declaring crate
`iceberg-catalog-glue`) also succeeds on 1.92.0. So the declared floor holds for
every configuration the package can be built in, not only the one CRAN compiles.

Should a future `iceberg-rust` release genuinely need a newer compiler, the
fallback is to pin an earlier one: 0.9.1 declares 1.92 and costs only
`CatalogBuilder::with_runtime`, which this package does not use. It was not
needed here, so no dependency was downgraded and no functionality was traded
away.

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
