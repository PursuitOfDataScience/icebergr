# Developing icebergr

Notes for maintaining an R package with a Rust core. If your other packages are
pure R, the unfamiliar part here is not the Rust — it is the build system, and it
is worth understanding before the first thing goes wrong.

## Setting up

```sh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
rustup update stable
rustc --version   # must be >= 1.94
```

That is the whole toolchain. `cargo` fetches and compiles dependencies itself; it
does not need a system package manager.

R side:

```r
install.packages(c("nanoarrow", "rlang", "tibble", "testthat", "devtools", "rextendr"))
```

## Day-to-day loop

**Always set `NOT_CRAN=true` while developing.** It tells `tools/config.R` to let
cargo use the network and to keep the build directory, which turns a rebuild from
minutes into seconds:

```sh
NOT_CRAN=true R CMD INSTALL --preclean .
```

or from R:

```r
Sys.setenv(NOT_CRAN = "true")
devtools::load_all()
devtools::test()
```

Without `NOT_CRAN`, every build is treated as a release build: offline, cleaned
afterwards, and slow. Do that deliberately before a release, not while iterating.

The first build compiles 343 crates and will take a long time — ten minutes or
more is normal. Subsequent builds reuse `src/rust/target/` and are fast, as long
as you have not run the clean path.

## How the build actually works

```
R CMD INSTALL
  └─ configure                       (must be executable — check `git ls-files -s configure`)
      └─ Rscript tools/config.R
          ├─ tools/msrv.R            checks rustc exists and is new enough
          └─ writes src/Makevars     from src/Makevars.in, substituting:
                                       @CRAN_FLAGS@   -j 2 --offline, or empty
                                       @FEATURES@     --features ..., from
                                                      ICEBERGR_CARGO_FEATURES
                                       @PROFILE@      --release, or empty
                                       @LIBDIR@       release, or debug
                                       @CLEAN_TARGET@ what to delete afterwards
  └─ make -f src/Makevars
      └─ cargo build --lib           produces libicebergr.a
      └─ links src/entrypoint.c      forwards R_init_icebergr into Rust
```

Two things about that chain trip people up:

- `src/Makevars` and `src/Makevars.win` are **generated**. Never edit them; edit
  the `.in` templates. They are gitignored and `.Rbuildignore`d for that reason.
- `src/entrypoint.c` exists so the linker does not discard the static library as
  unreachable. Without it the package compiles and then fails to load with a
  missing-symbol error. If you rename the package, `R_init_<pkg>` in
  `entrypoint.c`, `src/icebergr-win.def` and `useDynLib` in `NAMESPACE` all have
  to change together.

## Adding a binding

Five places, in order. Missing any one of them produces a confusing failure
rather than a clear error.

1. **Write the Rust function** in the relevant `src/rust/src/*.rs`, marked
   `#[extendr]`.
2. **Register it** in that file's `extendr_module! { }` block.
3. **Declare the R wrapper** in `R/extendr-wrappers.R`, calling
   `.Call(wrap__<fn_name>, ...)`. `rextendr::document()` regenerates this file if
   you have a working build; otherwise add the line by hand and match the
   pattern.
4. **Write the user-facing R function** that validates arguments and calls it.
   Keep the Rust side thin: argument checking, tibble construction and error
   messages are all easier to write, read and test in R.
5. **Export it** — roxygen `@export`, then `devtools::document()`.

Names must match exactly across steps 1–3. A typo shows up as
`object 'wrap__rs_whatever' not found`.

## Checking the Rust without R

Much faster than a full `R CMD check`, and it catches most mistakes:

```sh
cargo fmt   --manifest-path src/rust/Cargo.toml
cargo check --manifest-path src/rust/Cargo.toml --all-targets
cargo clippy --manifest-path src/rust/Cargo.toml -- -D warnings
```

`cargo check` type-checks without linking, so it does not need libR. Run it
before `R CMD INSTALL` — a type error found in 30 seconds beats one found after a
ten-minute build.

## Optional features

Off by default, because each substantially enlarges the dependency tree:

```sh
ICEBERGR_CARGO_FEATURES=s3   NOT_CRAN=true R CMD INSTALL --preclean .
ICEBERGR_CARGO_FEATURES=glue NOT_CRAN=true R CMD INSTALL --preclean .
```

`icebergr_spec_support()$cargo_features` reports what a given install has. Code
paths that need an absent feature raise an informative error rather than failing
at link time — see `errors::not_compiled_in`.

## Releasing

```r
Rscript tools/vendor.R          # needs network; writes vendor.tar.xz + LICENSE.note
```

Then build and check with `NOT_CRAN` **unset**, which exercises the offline path
that a release actually uses:

```sh
R CMD build .
R CMD check --as-cran icebergr_*.tar.gz
```

`tools/vendor.R` also prints the vendored size, which is the number the CRAN size
exemption request rests on. See `FEASIBILITY.md` §8d for what it is made of and
what does and does not reduce it.

### Pre-submission checklist

Things that need a human, and cannot be done by CI:

- [ ] Email `trademarks@apache.org` describing the package and the name, and keep
      the reply. See `FEASIBILITY.md` §1a — this is the one item that is a
      genuine external dependency rather than a task.
- [ ] Reconfirm the name is free with `available.packages()`, not just against
      the GitHub CRAN mirror (`FEASIBILITY.md` §6).
- [ ] Re-read "Using Rust in CRAN packages" and the Repository Policy directly;
      both move.
- [ ] Re-run `Rscript tools/vendor.R` so `vendor.tar.xz` and `LICENSE.note` match
      the `Cargo.lock` being shipped, and update the measured figures in
      `cran-comments.md`, `NEWS.md` and the README if they have moved.
- [ ] Fill in the "Test environments" and "R CMD check results" sections of
      `cran-comments.md` from the actual submission run.

## Things that will go wrong, and what they mean

| Symptom | Cause |
| --- | --- |
| `configure: Permission denied` | `configure` lost its executable bit. `git update-index --chmod=+x configure` |
| `object 'wrap__rs_x' not found` | Binding missing from `extendr_module!` or from `R/extendr-wrappers.R` |
| Package installs, then fails to load with a missing symbol | `entrypoint.c` name does not match the package name |
| `UNSUPPORTED RUST VERSION` | `rustup update stable`. The required version comes from `SystemRequirements` in `DESCRIPTION` |
| Undefined references to `ws2_32`, `bcrypt`, `ntdll` on Windows | A crate needs a Windows system library not in `PKG_LIBS`. The `--print=native-static-libs` output in the build log lists the authoritative set |
| `error: no matching package named ...` during an offline build | `vendor.tar.xz` is stale. Re-run `tools/vendor.R` |
| Builds are mysteriously slow every time | `NOT_CRAN` is unset, so each build is a cleaned release build |
| Tests hang | A `block_on` was reached from inside the tokio runtime. Every entry point must be called from R's thread; see `src/rust/src/runtime.rs` |
| `Failed to convert between uuid und iceberg value, invalid character: found \`x\`` | Not a data problem. A metadata file whose name is not `<version>-<uuid>.metadata.json`; the stray character is the first letter of the file name. Iceberg derives the next name from the current one. Test fixtures must use `metadata_file_name()` |
| A `decimal` filter returns no rows | `iceberg-rust` 0.10.0's row-selection filter discards every row of an ordering comparison on a decimal. `configure()` in `scan.rs` turns that stage off when the predicate touches one; do not remove it |
| `struct<doubledouble>` in a schema | `iceberg::spec::Type`'s own `Display` runs a struct's child types together with no names. `table.rs::type_label()` exists for this; do not replace it with `to_string()` |
| Hidden-file NOTE naming a dot-directory | It is in the tarball but not in `.Rbuildignore`. Local tooling state belongs in both that and `.gitignore` |

## Design decisions worth not undoing

- **Snapshot ids are character, not numeric.** Iceberg assigns them as random
  64-bit integers; R numerics carry 53 bits. A double round trip silently selects
  the wrong snapshot, which is worse than an error.
- **Scan schemas come from the first batch**, not from converting the Iceberg
  schema. A C stream whose schema disagrees with its arrays is undefined
  behaviour in the consumer.
- **Credentials are never function arguments.** They come from environment
  variables, are never printed, and never appear in error messages — only
  property *keys* do. `errors::config_err` exists to enforce that.
- **Filters are translated in R, typed in Rust.** `iceberg-rust` has no
  expression parser, so `R/filter.R` emits a JSON predicate tree and
  `src/rust/src/predicate.rs` types each literal from the *column's* declared
  Iceberg type. Literals bind against the snapshot's schema, not the current one.
- **The test fixture is generated, not committed.** Iceberg records absolute paths
  in metadata and in Avro manifests, so a committed table does not survive being
  installed elsewhere. `icebergr_example_table()` builds one on demand.
- **`as_of` resolves against the snapshot *log*, not the snapshot list.** A
  rollback appends a log entry pointing back at an earlier snapshot while leaving
  the abandoned one in the list with its own, later, timestamp. Resolved against
  the list, a rolled-back table read as of *now* returns the one state it
  demonstrably was not in.
- **Name resolution prefers an exact match, and refuses ambiguity.** Iceberg
  column names are case-sensitive, so a schema may hold both `id` and `ID`.
  `column_index()` in `R/utils.R` returns an exact match ahead of a
  case-insensitive one and errors when a name matches two columns and neither
  exactly. `predicate.rs::reference` mirrors it, because the upstream
  case-insensitive index is a map keyed on the lowercased name and its winner is
  arbitrary.
- **An append is refused *before* anything is written.** Both for a partitioned
  table and for a metadata file name Iceberg cannot derive a successor from.
  Iceberg discovers each only at the commit, by which point the Parquet is in the
  warehouse, unreferenced by any snapshot, with no maintenance operation here to
  remove it. `metadata_name_is_committable()` deliberately mirrors
  `MetadataLocation::parse_file_name` rather than being stricter.
- **Row selection is disabled for a decimal predicate**, in `scan.rs::configure`.
  In `iceberg-rust` 0.10.0 that stage discards every row of an ordering comparison
  against a decimal while leaving equality alone, so `price > 2.25` silently
  returned nothing. File and row-group pruning still apply. Re-measure before
  assuming a newer upstream has fixed it.
- **`type_label()` renders Iceberg types, not `Display`.** Upstream writes a
  struct as its children's types run together with no names or separator —
  `struct<doubledouble>` — and a list or map as a bare word.
- **The `int64` prototype recurses.** A `long` inside a `struct` loses precision
  exactly as a top-level one does; `rewrite_int64()` descends. `list` and `map`
  are deliberately left alone, since their prototypes are not data frames.

## Verifying a claim before making it

The feature matrix in `R/spec-support.R` is the package's honesty artifact, and
twice now a row in it has been wrong in a way only a check against reality would
catch: `map` was claimed to round trip when nanoarrow cannot build a map array,
and overwrite writes were blamed on this package's scope when `iceberg-rust` has
no overwrite action at all. Two habits follow.

- **Attribute the gap to whoever owns it.** A user deciding whether to wait for
  the next `icebergr` or reach for another engine needs to know which. Check the
  vendored source before writing "not implemented in iceberg-rust": as of 0.10.0
  the transaction API has exactly eight actions, none of which overwrites or
  rewrites, but an `equality_delete_writer` *does* exist — the gap there is the
  commit path, not the writer.
- **Exercise a capability before claiming it.** Positional and equality delete
  *reads* remain the one row asserted on upstream's behalf rather than tested,
  because producing delete files needs another engine.
