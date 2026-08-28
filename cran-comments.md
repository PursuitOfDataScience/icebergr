# cran-comments.md

## This is a resubmission

The previous submission (0.1.0, 2026-08-27) passed the pre-tests and was returned
with one request: the 33,048,416-byte tarball had to come under 10 MB, with an
explanation if the Rust crates were all genuinely needed.

**The tarball is now 11,170,566 bytes, a 2.96x reduction, and nothing was
dropped from what a default install can do.** The reduction and the explanation
are together under "The size request" below. In short: `cargo vendor` writes
every entry in `Cargo.lock`, which is a union over all platforms and all optional
features, and 172 of the 442 crates it wrote are never compiled on any platform R
runs on — including the 63 MB of BoringSSL that only the opt-in AWS Glue backend
reaches. Those now ship as a manifest and a licence rather than as source, which
is 222 MB of the 274 MB removed. No dependency was changed, added or removed.

Changes in this version:

* `tools/vendor.R` reduces the vendor tree before compressing it, in five
  stages, each driven by what `cargo tree` reports rather than by a
  hand-written list, and each verified afterwards by `cargo metadata --offline
  --locked` and by an `include_str!` scan.
* `tools/config.R` and `src/Makevars{,.win}.in` gained one condition: the
  archive is unpacked, and `--offline` passed, only when no optional Cargo
  feature has been requested. The pruned archive covers the default build, so a
  feature build resolves from crates.io instead of failing inside a compile.
* `LICENSE.note` now records, per crate, whether it is compiled or shipped as a
  manifest only. All 442 are still inventoried and credited.

Nothing else changed: no R code, no Rust code, no documentation beyond the notes
on those two points, and no dependency versions.

## The submission before that

The submission of 0.1.0 on 2026-08-27 was rejected by the incoming
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

The size request below has been rewritten around what was actually measured
this time, and it corrects a claim I made in the previous one.

## Test environments

- Local: CentOS Linux 8 (x86_64), R 4.6.0, rustc 1.97.1 — vendored, offline
  build, the same path a CRAN build takes.
- Local: the same machine and R, with **rustc 1.92.0** — the version the Windows
  farm reported — again vendored and offline. Added for this resubmission.
- GitHub Actions: ubuntu-latest (R release and R oldrel-1), macos-latest
  (R release), windows-latest (R release), building against crates.io.
- GitHub Actions: one job vendors every dependency and publishes the resulting
  `vendor.tar.xz`, and a three-platform matrix — ubuntu-latest, macos-latest and
  windows-latest — then builds and checks **that same archive** with no network
  access at all, reproducing the CRAN build path. Extended to macOS and Windows
  for this resubmission, because the reductions described below prune crates
  that only those two platforms compile and Linux alone cannot show that to be
  safe. The vendoring job re-derives the archive from scratch on a clean runner
  and arrives at the same 10.47 MB and the same per-stage figures quoted below.
- GitHub Actions: a job that reads the floor out of `SystemRequirements` and
  type-checks the whole tree on exactly that toolchain, so the declared minimum
  cannot drift without CI going red. It installs rustc 1.92.0 and processes the
  whole default graph with no warnings. Every job above passed on the submitted
  tree, both windows-latest jobs included.

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
  whenever the vendored archive is present, `NOT_CRAN` is unset and no optional
  Cargo feature has been requested — see the size request below for why the last
  condition is now there.
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

#### The size request

You asked me to bring the tarball under 10 MB, and to explain the Rust crates if
they really are all needed. Both, in that order.

**The tarball is now 11,170,566 bytes, down from 33,048,416 — a 2.96x
reduction.** All of it came out of `tools/vendor.R`, which now reduces the vendor
tree before compressing it rather than only compressing it. Uncompressed, stage
by stage:

| | uncompressed |
| --- | --- |
| what `cargo vendor` writes | 442 crates, 373.8 MB |
| less tests, examples, benchmarks, fuzz targets, CI config, fixtures | -27.4 MB |
| less changelogs, each crate's own `Cargo.lock`, the `Cargo.toml.orig` copy | -9.7 MB |
| less `#[cfg(test)]` modules inside `src/`, `cargo-public-api` snapshots | -1.3 MB |
| less `windows-sys` bindings behind features nothing enables (219 of its 246 API modules) | -14.1 MB |
| less the 172 crates that no build on any platform R runs on compiles | -221.5 MB |
| shipped | 442 crates, 97.3 MB, compressing to 10.46 MB (10,970,960 bytes) |

That last row corrects something I got wrong in the previous submission. I wrote
there that the crates cargo vendors but never compiles "cannot be pruned,
because cargo resolves the whole lock graph before it selects features or
filters targets". The premise is right — an offline build really does fail with
`no matching package named ...` if a locked package is absent from the directory
source — but the conclusion was not. Cargo needs to *find* those packages; it
never reads them. They now ship as their `Cargo.toml`, their licence files and
an empty `lib.rs`: 172 crates in 0.5 MB rather than 222 MB. `aws-lc-sys` is the
clearest case. It is 63 MB of BoringSSL, it was the largest single item in the
previous tarball, and it is reachable only through the opt-in `glue` Cargo
feature, so no CRAN build has ever compiled a line of it.

Two consequences worth stating plainly:

- The archive now covers the **default** build only. A user who opts into the S3
  or AWS Glue backend with `ICEBERGR_CARGO_FEATURES` gets those roughly hundred
  extra crates from crates.io instead, because cargo replaces the crates.io
  source wholesale when a directory source is configured and so cannot fetch
  just the missing few. `tools/config.R` detects that case, does not unpack the
  archive, does not pass `--offline`, and says so. A default install — the only
  kind CRAN performs — still touches the network at no point.
- Every stage is derived from what cargo itself reports rather than from a
  hand-maintained list: `cargo tree --target ... -e normal,build` for the
  compiled set, `cargo tree -f "{p} :: {f}"` for which `windows-sys` features
  are on. A dependency update therefore cannot silently make the pruning wrong.
  `tools/vendor.R` also checks the result twice before writing the archive, with
  `cargo metadata --offline --locked` against the pruned tree and with a scan
  for markdown that a compiled crate pulls into its rustdoc via `include_str!`.
  Both checks exist because both caught a real mistake while I was writing this.

**On whether the remaining 10.46 MB is all needed: it is 270 crates of source,
every one of which is compiled into the shared object, and there is no longer
anything in it that dominates.** Compressed individually, the ten largest are
`ring` 0.89 MB, `parquet` 0.51, `brotli` 0.48, `tokio` 0.44, `zstd-sys` 0.43,
`regex-automata` 0.38, `iceberg` 0.37, `libc` 0.37, `windows-sys` 0.35 and
`rustls` 0.25 — 4.45 MB in total. The other 432 directories average 22 KB each.

The shape of that list is the explanation. Apache Iceberg's data path is Arrow
and Parquet and its metadata path is Avro, so the `iceberg` crate depends
unconditionally on twelve `arrow-*` crates, `parquet`, `apache-avro` and the
compression codecs those two require; a REST catalog is HTTPS, so it also
depends on `tokio`, `hyper`, `reqwest`, `rustls` and `ring`. `iceberg` declares
`[features] default = []` and has no optional dependencies at all, so there is
no feature configuration that removes any of it, and 264 of the 270 are compiled
on a single machine — the extra six are the macOS and Windows system bindings.

**For scale.** `arcgisgeocode` is on CRAN today at **13 MB**, with the same
`SystemRequirements` profile as this package — `Cargo (Rust's package manager),
rustc, xz` — and no data in it, so its size is vendored Rust and nothing else.
Checked against the current listing in `src/contrib/` rather than remembered:
`arcgisgeocode_0.4.0.tar.gz`, 13M, and `prqlr_0.10.1.tar.gz` at 9.0M is the next
one down. At 10.7 MB this package would be smaller than an exception already
granted for exactly this reason, which is the main ground on which I am asking.

**On the separate-package suggestion.** You mentioned that data can go in a
separate package that is only infrequently updated. This package ships no data at
all — outside `vendor.tar.xz` the whole tarball is 199,606 bytes — so that route
does not apply literally, but the analogous move does exist and I want to be
straight about it rather than leave it unaddressed: a companion package
containing nothing but the vendored archive and a function returning its path,
with this package's `configure` locating it.

It would not get either package under 10 MB, since the companion would be the
same 10.46 MB and would need the same exception. What it would do is answer what
I take to be the underlying concern. The bulk changes only when `iceberg-rust`
does, which is a few times a year, whereas this package will see the ordinary
rate of bug-fix releases; splitting them would mean the frequently-updated
package is ~200 KB and your mirrors carry the 10 MB rarely instead of on every
release.

I have not done it because it makes an installation depend on a second package
being present at *build* time, which is unusual enough that I would rather not
invent it unilaterally, and because it is your infrastructure the trade-off is
about. If you would prefer that shape, say so and I will restructure it; if the
exception is simpler for you, this submission is that.

One further reduction of about 0.6 MB does exist and I have not taken it.
Parquet supports Brotli as a column codec, and `brotli` plus
`brotli-decompressor` are 6.2 MB of source and 0.62 MB of the archive. Setting
`default-features = false` on our own `parquet` dependency does not remove it:
`iceberg` depends on it with default features on, and cargo unions features
across the graph rather than intersecting them, so the only way to drop Brotli
is to override a feature inside the bundled `iceberg` manifest — a modification
to a third-party crate, in exchange for not being able to read
Brotli-compressed Parquet data files. That seemed the wrong trade to make
silently, but it is available if you would rather have the 0.6 MB than the
codec.

So the request is for 10.7 MB rather than the 31.5 MB of the previous
submission. I recognise that is still over the guidance. If it is not acceptable
I would value knowing what number is, and I will either find it or withdraw
rather than press the point.

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
