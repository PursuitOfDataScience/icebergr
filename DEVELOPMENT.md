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

`tools/vendor.R` also prints the vendored size. See `FEASIBILITY.md` for why that
number matters and why CRAN is not currently a viable target.

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
