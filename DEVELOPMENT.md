# Developing icebergr

Notes for maintaining an R package with a Rust core. If your other packages are
pure R, the unfamiliar part here is not the Rust — it is the build system, and it
is worth understanding before the first thing goes wrong.

## Setting up

```sh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
rustup update stable
rustc --version   # must be >= 1.92
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
`object 'wrap__rs_whatever' not found`, and a wrong *argument count* shows up as
`Incorrect number of arguments (n), expecting m` on every call — which is easy to
introduce whenever `rextendr` is unavailable and step 3 is done by hand.

Neither mistake needs a build to catch. This checks all three lists agree, and
that every wrapper's arity matches its Rust signature:

```sh
python3 - <<'PY'
import re, glob
src = "\n".join(open(f).read() for f in sorted(glob.glob("src/rust/src/*.rs")))
def arity(after):                      # count top-level params from just past "("
    d, n, seen = 1, 0, False
    for c in src[after:]:
        if c in "([<{": d += 1
        elif c in ")]>}":
            d -= 1
            if not d: break
        elif d == 1 and c == ",": n += 1
        if d >= 1 and not c.isspace(): seen = True
    return n + 1 if seen else 0
rust = {m.group(1): arity(m.end()) for m in re.finditer(
    r"#\[extendr\][^\n]*\n(?:\s*#\[[^\]]*\]\s*\n)*\s*fn\s+(rs_[a-z_0-9]+)\s*\(", src)}
mod = set(re.findall(r"fn\s+(rs_[a-z_0-9]+);", src))
w = open("R/extendr-wrappers.R").read()
rw = {m.group(1): len([a for a in m.group(2).split(",") if a.strip()])
      for m in re.finditer(r"^(rs_[a-z_0-9]+)\s*<-\s*function\((.*?)\)\s*[\{\.]", w, re.S|re.M)}
print("not registered:", sorted(set(rust) - mod) or "ok")
print("no R wrapper  :", sorted(mod - set(rw)) or "ok")
print("arity mismatch:", [(n, rust[n], rw[n]) for n in rust if n in rw and rust[n] != rw[n]] or "ok")
PY
```

Last run: 25 functions, all three lists agreeing, every arity matching, and every
wrapper reached from `R/` or `tests/`.

## Checking the Rust without R

Much faster than a full `R CMD check`, and it catches most mistakes:

```sh
cargo fmt   --manifest-path src/rust/Cargo.toml
cargo check --manifest-path src/rust/Cargo.toml --all-targets
cargo clippy --manifest-path src/rust/Cargo.toml -- -D warnings
LD_LIBRARY_PATH="$(R RHOME)/lib" \
  cargo test --manifest-path src/rust/Cargo.toml --lib
```

`cargo check` type-checks without linking, so it does not need libR. Run it
before `R CMD INSTALL` — a type error found in 30 seconds beats one found after a
ten-minute build.

`cargo test` is for the pure-Rust helpers whose inputs are awkward to reach from
R — anything taking a path or a file name, in particular. It earns its place:
`metadata_name_is_committable()` split a path on `/` only, which refused every
append on Windows and passed on every other platform, so a single OS's R tests
were the only thing standing between that and a release. Note that `cargo check
--all-targets` compiles `#[cfg(test)]` code without running it, which is not the
same thing.

Nothing in these tests may **call into R** — there is no R session under a test
binary — but they may use `extendr`'s own types, and `predicate.rs`'s do: `datum()`
returns `RResult`, and what is worth pinning about it is that a bound past
`i64::MAX` is refused rather than clamped. That is why the command above sets
`LD_LIBRARY_PATH`. `cargo test` builds a binary, that binary links libR
(`readelf -d` shows `NEEDED libR.so` and no RPATH), and nothing puts R's library
directory on the loader path for a bare process the way `R CMD ...` does. Without
it the harness dies before the first test with

```
error while loading shared libraries: libR.so: cannot open shared object file
```

It needed no such help for as long as every test was a string function, because
`ld --as-needed` leaves libR out when nothing references an R symbol. So this is
a wall that appears the first time a unit test touches `extendr`, on a commit
that changed nothing about linking — which is exactly how CI met it.

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

**On any `iceberg-rust` or `arrow` bump, the version is carried by hand in
thirteen files and nothing will catch a stale one.** Two of them are reported to
users — `rs_build_info()` in `src/rust/src/lib.rs`, which is what
`icebergr_spec_support()` prints, and the `reason` strings in `feature_matrix()`
that name the version a gap belongs to. The test for it compares one hardcoded
string against another, so it passes either way. `grep -rn '0\.10\.0'` before
tagging, and check the reported version against `src/rust/Cargo.lock` rather than
against `Cargo.toml`, since a caret requirement can resolve higher than it reads.
The rustc MSRV does not have this problem: `tools/msrv.R` reads it from
`SystemRequirements` in `DESCRIPTION`, which is its single source of truth.

**But that value is the floor the package has been *checked* against, which is
not the maximum `rust-version` declared in the tree.** Conflating the two is what
broke the first CRAN submission. `iceberg`, `iceberg-catalog-rest`,
`iceberg-catalog-glue` and `fastnum` all declare 1.94 under iceberg-rust's
rolling-MSRV policy, nothing else in the tree exceeds 1.91.1, and none of the
four uses a language or library feature newer than 1.92 — but CRAN's Windows
farm carries 1.92.0, and cargo refuses a build outright when a *dependency*
declares more than the active toolchain, so the install never reached the
compiler. `src/Makevars{,.win}` therefore pass `--ignore-rust-version`, which
makes `tools/msrv.R` the only gate.

The consequence for maintenance: raise `SystemRequirements` only after building
and running the test suite on the new floor, and lower it whenever a measurement
shows an older toolchain works. Note also that `fastnum` is a direct non-optional
dependency of `iceberg` rather than of `iceberg-rust`, so the documented fallback
of pinning 0.9.1 would not by itself have dropped the declared maximum.

That declared maximum is still worth knowing, since it is what you would have to
satisfy if the flag were ever dropped. Compute it from an extracted vendor tree:

```sh
tar xf src/rust/vendor.tar.xz -C /tmp && grep -rhE '^\s*rust-version\s*=' /tmp/vendor/*/Cargo.toml |
  sed -E 's/.*"([0-9.]+)".*/\1/' | sort -uV | tail -1
```

Measure that tree's size with `find -printf '%s\n'`, not `du`: this filesystem
compresses, so `du -sm` reported 123 MiB for a tree whose files total 343.9 MiB.

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
| `mclapply()` hangs, with no error | The runtime's worker threads do not survive `fork()`. `TOKIO` is a `OnceLock`, so a forked child inherits it already initialised and `block_on` waits on threads that never came across. Measured: forking *before* any call is fine, forking after the runtime has started deadlocks. Documented in the catalog-configuration vignette as "use a PSOCK cluster". Not fixed in 0.1.0 — a fix means keying the runtime on `std::process::id()` and rebuilding it after a fork, which changes `block_on`'s return type or its `'static` lifetime and so touches every entry point. `check_live_ptr()` cannot catch it: after a fork the pointer really is valid |
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
- **Every per-column helper in `arrow-bridge.R` recurses into data frame
  columns**, because a data frame column is how a `struct` arrives. All three had
  to learn this separately, so treat it as the rule for any new one:
  `rewrite_int64()` (a `long` inside a struct loses precision exactly as a
  top-level one does), `normalise_timestamps()` (a naive `POSIXct` inside a struct
  otherwise reaches nanoarrow as the *session's* zone, and `create_table()` fails
  with `Unsupported Arrow data type: Timestamp(us, "America/Chicago")` on a data
  frame that works on a UTC machine), and `canonicalise_utc()` (a nested
  `timestamptz` otherwise keeps `"+00:00"` and warns `'tzone' attributes are
  inconsistent`). `list` and `map` are deliberately left alone, since their
  columns are not data frames.
- **A `long` filter literal is range-checked, not cast.** `f as i64` *saturates*
  in Rust, so `id == 1e19` quietly became `id == 9223372036854775807` and returned
  whichever rows hold `i64::MAX`. `as_i64()` in `predicate.rs` bounds against
  2^63 rather than against `i64::MAX as f64`, which rounds *up* to 2^63 and would
  let through the one value that cannot convert.

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
