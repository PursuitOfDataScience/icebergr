# `icebergr` for R — pre-implementation feasibility report

**Date:** 2026-08-06
**Author:** Youzhi Yu
**Status:** CRAN remains the target. Two quantitative obstacles identified (vendored size, MSRV) with routes through both; naming changed for trademark reasons. Approach retained.

This report is the output of the "BEFORE WRITING ANY CODE" step: verify the
premise, read the current CRAN policy on Rust, and establish what
`iceberg-rust` actually supports today. Several of those checks came back
negative in ways that changed the plan.

Sections 1–7 are the report as written before implementation. **Section 8 is an
addendum recording what turned out to be wrong once the package was built** —
kept separate rather than edited in, so the original reasoning stays auditable.

---

## 1. The premise checks out

| Claim | Verdict | Evidence |
| --- | --- | --- |
| No Apache-governed Iceberg client for R | **Confirmed** | Apache maintains Java, Python (PyIceberg), Rust and Go implementations. No R implementation exists in the ASF. |
| `iceberg` is free as a CRAN package name | **Confirmed available** | Never published to CRAN. `riceberg` and `icebergr` are also free. See caveat in §6 on how this was checked. |
| Iceberg is the industry standard table format | Confirmed | Snowflake, Databricks, BigQuery, AWS and Dremio have all standardised on it. |
| Parquet is well served in R; Delta Lake has a community Rust binding | Confirmed | `arrow` and `nanoarrow` are both on CRAN. |

The README hook — *"R is the only major data language without an Apache Iceberg
client"* — is accurate and worth keeping.

## 1a. The name has to change: `iceberg` is a trademark problem

Separate from licensing, and more restrictive. ASF trademark policy states that
*"third parties may not use Apache trademarks in the primary or secondary
branding of any third party product or service names"*, and that a third party
*"may not apply trademarks to your derivative works ... that are confusingly
similar to 'ProjectName' or 'Apache ProjectName'."* Nominative use — describing
what the software works with — **is** permitted.

A CRAN package named exactly `iceberg` is the mark itself as primary branding.
It is also actively misleading here: the ASF governs the Java, Python, Rust and
Go clients, so a bare `iceberg` on CRAN reads as the official R one. `arrow` and
`duckdb` are bare on CRAN because they *are* the official packages, maintained by
their respective projects. We do not have that standing.

`icebergr` was chosen. It still incorporates the mark, which is not risk-free —
note that `pyiceberg` is an *official* ASF project, so the `<lang> + mark` pattern
can read as ASF ownership rather than distance from it. Mitigations applied:

- `NOTICE` carries an explicit trademark attribution and a disclaimer of
  affiliation, and states that this is not one of the official clients.
- The same disclaimer appears in `DESCRIPTION`, the README and the package
  documentation.
- The Title uses the mark only nominatively: "Read and Write Apache Iceberg
  Tables".

**Recommended before any public release:** email `trademarks@apache.org`
describing the package and the name, and keep the reply. A distinct name not
containing the mark at all (`icefloe` and similar) would carry no trademark risk,
at the cost of discoverability that the Title largely recovers anyway.

## 2. Licensing: compatible, with conditions

`iceberg-rust` is **Apache-2.0** (`license = "Apache-2.0"` in the workspace
manifest; `LICENSE` is the Apache 2.0 text; the repo carries a `NOTICE` file).

Apache-2.0 is **one-way compatible with GPL-3.0**: Apache-2.0 code may be
incorporated into a GPL-3.0 work, and the combined work is distributed under
GPL-3. It is *not* compatible with GPL-2.0, which is why `GPL (>= 3)` — the
house style — is the correct choice and `GPL (>= 2)` would not be.

Conditions that come with it, all of which are routine:

- Preserve the upstream `NOTICE` content and the Apache-2.0 licence text.
- Enumerate the authorship and licence of **every vendored crate**. The
  established CRAN pattern is a top-level `LICENSE.note` file; `polars` shipped
  a 52 KB one. For our dependency tree this file will be large (see §4).
- Apache-2.0's patent grant and attribution clauses survive into the combined
  work.

No blocker here.

## 3. `iceberg-rust` feature audit (pinned at v0.10.0, released 2026-07-07)

Read directly from the upstream source tree at commit `f28ae7d`.

**Supported, and a good fit for the intended v0.1.0 surface:**

| v0.1.0 need | Upstream API | Status |
| --- | --- | --- |
| Predicate pushdown | `TableScanBuilder::with_filter(Predicate)` | Available |
| Projection pushdown | `TableScanBuilder::select(cols)` / `select_all` | Available |
| Time travel by snapshot | `TableScanBuilder::snapshot_id(i64)` | Available |
| Arrow interchange | `TableScan::to_arrow() -> ArrowRecordBatchStream` | Available |
| Append-only writes | `transaction/append.rs` | Available |
| Catalog listing | `list_namespaces`, `list_tables`, `load_table` | Available |
| Row-group / row-level scan pruning | `with_row_group_filtering_enabled`, `with_row_selection_enabled` | Available — this is the real pushdown win |
| Snapshot history | `table.metadata().snapshots()` | Available |

Also present upstream, beyond our scope: `expire_snapshots`, `update_schema`,
`update_properties`, `sort_order`, `update_location`,
`upgrade_format_version`, Puffin, encryption, delete-vector *reads*.

**Not supported upstream — must be documented as unsupported, not left to fail obscurely:**

- **MERGE / UPDATE / row-level DELETE writes.** No path through the transaction
  API. Copy-on-Write and Merge-on-Read are an open upstream epic. (Already on
  the "do not build" list — but the reason is upstream absence, not just scope.)
- **Compaction and maintenance operations.**
- **Partition evolution.**
- **No row `limit` in the scan builder.** `iceberg_scan(limit=)` cannot be
  pushed down; it has to be applied R-side after the Arrow stream. This must be
  documented, because a `limit` that looks like pushdown but isn't is a
  performance trap.
- **No `as_of` timestamp on the scan builder.** Timestamp-based time travel has
  to be implemented in R by resolving the timestamp against snapshot history to
  a `snapshot_id`. Straightforward, but it is our code, not upstream's.

### 3a. There is no Hadoop catalog — this breaks the planned test strategy

The v0.1.0 API in the plan specifies `iceberg_catalog(type = c("rest", "glue",
"hadoop"))`, and the testing requirement is a bundled fixture using a *"hadoop
catalog on local filesystem"*.

**`iceberg-rust` has no `HadoopCatalog` and no filesystem catalog.** The
catalogs that exist are:

`MemoryCatalog` (in the core crate), `rest`, `glue`, `hms`, `sql`, `s3tables`.

The offline-fixture requirement is still satisfiable, and cleanly:
`Catalog::register_table(&ident, metadata_location)` exists, so a tiny Iceberg
table can be committed to `inst/` and registered into a `MemoryCatalog` whose
warehouse points at the bundled directory. That gives fully offline tests with
no network and no credentials. The `sql` catalog (SQLite-backed) would persist
the catalog mapping too, but it drags in `sqlx` and materially increases an
already-large dependency count (§4).

**Consequence for the public API:** `type=` should be
`c("rest", "glue", "memory")` — advertising `"hadoop"` would promise something
the backend cannot do.

## 4. CRAN + Rust: the two quantitative obstacles

CRAN's current policy (`Using Rust in CRAN packages`, plus the Repository
Policy) requires, as of today:

- All Rust dependencies **vendored into the package**, conventionally as
  `src/rust/vendor.tar.xz`.
- **No network access during the build.** Cargo must not download or check out
  any source at build time.
- **Authorship and copyright for all Rust code, including dependencies**,
  recorded in the package.
- `CARGO_HOME` confined to the build directory, and cargo's job count pinned
  (`-j2`) because cargo otherwise defaults to all logical CPUs, exceeding
  policy.
- Source tarballs **should not exceed 10 MB**; a "modestly increased limit" can
  be requested at submission.

The policy permits Rust. The problem is arithmetic.

### 4a. Dependency weight

Transitive closure computed from the upstream `Cargo.lock`, excluding
dev-dependencies:

| Configuration | Vendorable crates |
| --- | --- |
| `iceberg` core alone | **343** |
| `iceberg` + REST catalog | **347** |
| `iceberg` + REST + Glue + opendal storage | **517** |

343 is the **floor**, not a starting point to optimise from: `iceberg`'s
`[features] default = []` is already empty, and `tokio`, `reqwest`, `parquet`,
the eight `arrow-*` crates and `apache-avro` are all unconditional
dependencies of the core crate. There is no feature-flag configuration that
gets this materially smaller.

Now compare against what CRAN has actually accepted. Measured from the released
sources of every vendoring Rust package I could find on CRAN:

| CRAN package | Version | Vendored crates | `vendor.tar.xz` | Published |
| --- | --- | --- | --- | --- |
| `b64` | 0.1.7 | 14 | 0.76 MB | 2025-07-14 |
| `awdb` | 0.1.3 | 23 | 1.15 MB | 2025-08-23 |
| `rsgeo` | 0.1.7 | 107 | 8.31 MB | 2024-07-10 |
| `prqlr` | 0.10.1 | 117 | 9.37 MB | 2025-03-28 |
| `arcgisgeocode` | 0.4.0 | 108 | **13.64 MB** | 2025-10-07 |

The observed ceiling is ~110 crates and ~13.6 MB — and 13.6 MB is already an
approved over-limit exception. Our floor is **343 crates, 3× that count**, and
the tree is composed of much heavier crates than any in the table above:
`arrow-*` and `parquet`, `apache-avro`, `tokio`, `rustls` with either `ring` or
`aws-lc-sys` (which alone carries tens of MB of vendored C and assembly), and
`zstd-sys` (bundled zstd C source).

A defensible estimate for `vendor.tar.xz` is **35–60 MB**, i.e. three to five
times the largest exception CRAN has ever granted. I could not measure this
exactly — see §6 — but the crate count is exact and the direction is not in
doubt.

### 4b. Rolling MSRV

`iceberg-rust` v0.10.0 requires **rustc 1.94** and **edition 2024**, and the
project states an explicit *rolling* MSRV policy: "at least three months from
latest rust release is supported. MSRV is updated when we release
iceberg-rust." The 0.10.0 release notes include "chore: Bump MSRV to 1.94".

Edition 2024 alone needs rustc ≥ 1.85. rustc 1.94 dates from March 2026.
CRAN's build machines run distribution-packaged toolchains that lag well
behind, and a dependency whose floor moves every release is structurally
hostile to a repository that rebuilds old packages against fixed toolchains
for years. Pinning an older `iceberg-rust` reduces the MSRV but forfeits the
features and bug fixes this package exists to expose.

### 4c. The closest precedent points away from CRAN

`polars` — the nearest comparable, being a heavy Rust + Arrow binding — *was*
on CRAN, at version 0.7.0, published 2023-07-17. Its `src/Makevars` runs a
bare `cargo build` with **no vendored dependencies at all**, i.e. it downloaded
from crates.io at build time. That is squarely disallowed under current policy,
the package is no longer on CRAN, and r-polars is distributed via r-universe
today. It is a precedent for *how this fails*, not for how it succeeds.

### 4d. Verdict

Neither obstacle is a policy prohibition — CRAN explicitly accommodates Rust.
Both are quantities, and quantities can be negotiated or reduced.

**As currently pinned, a submission would face two objections.** A vendored tree
around 3× the largest ever accepted, and a `rustc` requirement that may exceed
what CRAN's machines carry. Neither has been *tested* against CRAN; both are
inferred, one of them (§6) from an assumption I could not check.

Restated as work rather than as a verdict:

| Obstacle | Status | What resolves it |
| --- | --- | --- |
| Vendored size | 343 crates; tarball size being measured in CI | Aggressive pruning of the vendor tree, then a size exemption request built on the measured figure rather than an estimate |
| MSRV 1.94 | Unconfirmed whether CRAN has it | Confirm CRAN's `rustc`; if short, pin `iceberg-rust` 0.9.1 for MSRV 1.92 (see §5) |

## 5. Route to CRAN

CRAN is the destination. The sequence:

1. **Keep the build system CRAN-shaped and continuously exercised.**
   `configure`/`configure.win`, `src/Makevars{,.win}.in`, `-j2`, confined
   `CARGO_HOME`, `--offline`, `LICENSE.note`. The `check-vendored` CI job runs
   precisely the submission path on every commit, so it cannot rot between
   attempts.
2. **Measure, then minimise, the vendored tarball.** `tools/vendor.R` prunes
   tests, examples, benchmarks and fixtures while preserving every licence file,
   and reports the resulting size. Replace the 35–60 MB estimate in §4a with the
   measured number before deciding anything.
3. **Confirm CRAN's Rust toolchain version.** This is the single unverified input
   to the whole MSRV argument. If 1.94 is available, obstacle 2 evaporates.
4. **If it is not, pin down the MSRV ladder** — measured from upstream tags:

   | `iceberg-rust` | MSRV | Cost |
   | --- | --- | --- |
   | 0.10.0 (current pin) | 1.94 | — |
   | 0.9.1 | 1.92 | Loses `CatalogBuilder::with_runtime`; the runtime is inherited from the calling context, which is where `block_on` already puts us. Cheap. |
   | 0.8.0 | 1.88 | Predates the storage-factory refactor; needs real binding changes |

   Edition 2024 needs only 1.85, so the edition is not the binding constraint.
5. **Submit with the size justification prepared.** `cran-comments.md` carries a
   draft of it: why the tree cannot be trimmed by feature flags, what pruning
   already removes, and the precedent that an over-limit tarball has been
   accepted before.
6. **Correct the API surface**: `type = c("rest", "glue", "memory")`, no
   `"hadoop"`. Document `limit` as post-scan and `as_of` as R-resolved.
7. **Distribute via r-universe or GitHub in the meantime**, so users are not
   blocked on the submission timeline. That is a staging area, not the
   destination.

## 6. What I could not verify, and why

This session's container has a restrictive network egress policy. It permits
GitHub, and denies everything else relevant here. Verified by direct probe:

| Host | Result | Consequence |
| --- | --- | --- |
| `index.crates.io`, `static.crates.io`, `crates.io` | 403 *"Host not in allowlist"* | **`cargo vendor` is impossible. No Rust code can be compiled or tested.** |
| `cran.r-project.org`, `cloud.r-project.org`, `cran.rstudio.com` | blocked | Policy pages unreadable directly; `available.packages()` unavailable |
| `archive.ubuntu.com` | 403 | `apt-get install r-base-dev` fails |
| `conda.anaconda.org`, `prefix.dev`, `r-universe.dev` | blocked | No alternative route to an R installation |
| `github.com`, `codeload.github.com` | OK | Upstream source audit in §3 was done this way |

So, concretely:

- **R is not installed and cannot be installed here.** The name-availability
  check in §1 was therefore *not* done with `available.packages()`. It was done
  with `git ls-remote` against the `cran/<pkg>` GitHub mirror org, which
  mirrors every CRAN package including archived ones. `cran/iceberg`,
  `cran/riceberg` and `cran/icebergr` do not exist, while control probes
  (`cran/tidyEmoji`, `cran/arrow`, `cran/nanoarrow`) do. A package that never
  existed cannot have a stale mirror entry, so "available" is a safe
  conclusion; **it should still be reconfirmed with `available.packages()`
  before submission.**
- **The CRAN policy requirements in §4 were assembled from search-result
  extracts of `using_rust.html` and the Repository Policy, not from fetching
  the pages.** They match the policy as I understand it, but the exact current
  wording should be re-read directly before submission.
- **I could not check what `rustc` version CRAN's build machines actually run.**
  §4b asserts they lag behind 1.94; that is an inference from how distributions
  package Rust, not a measurement, and it is the single unverified input to the
  entire MSRV objection. If CRAN has 1.94, that obstacle does not exist. Confirm
  it before acting on the MSRV ladder in §5.
- **The 35–60 MB vendor estimate is an estimate.** The 343/347/517 crate counts
  are exact, computed from upstream's `Cargo.lock`; the comparison table in §4a
  is exact, measured from the packages' own released sources. Only the
  extrapolation to our tarball size is inferred.
- **No Rust or R code in this repository has been compiled, run, or checked**,
  because neither toolchain can reach its package registry from here. The
  "Definition of done" — `R CMD check` clean on Windows, macOS and Linux, with
  round-trip and time-travel tests passing — **cannot be met in this
  environment** and must be met in CI.

## 7. Open decision

The plan's own instruction was to stop and report if the policy makes this
infeasible. It is infeasible for CRAN today, though for reasons of dependency
weight and MSRV rather than policy text. The engineering is sound and the
feature audit is favourable; only the distribution target needs to change.

Awaiting a decision on §5 before writing bindings.

---

## 8. Addendum: corrections found during implementation

Three claims in the sections above turned out to be wrong. They are recorded here
rather than silently edited above.

### 8a. A bundled Iceberg table is not relocatable (corrects §3a)

Section 3a proposed committing a tiny Iceberg table to `inst/` and registering it
into a `MemoryCatalog` with `register_table()`. That does not work.

An Iceberg table records **absolute** paths — in its metadata JSON, and again
inside its Avro manifests. A table committed to the package would carry the build
machine's paths and stop resolving the moment it was installed anywhere else.
Rewriting them is not practical: the metadata is JSON, but the manifests are Avro,
and patching path strings inside Avro from R is not something to build a test
suite on.

The fixture is therefore **generated on demand** by `icebergr_example_table()`,
which builds a real two-snapshot table into a warehouse directory under
`tempdir()`. This keeps every requirement that mattered — a real Iceberg table,
fully offline, no catalog server, no credentials, usable from any install
location — and drops only the idea that the bytes could be committed.
`register_table()` is still exported, because it is exactly what a user needs to
re-attach an on-disk table to a `memory` catalog between sessions.

### 8b. Delete files *are* applied on read (corrects §3)

Section 3 listed reads of merge-on-read tables as unsupported. That was wrong, and
wrong in the dangerous direction: it would have told users their reads might be
silently incomplete when in fact they are correct.

`iceberg-rust` applies both positional and equality deletes during scanning —
`crates/iceberg/src/arrow/reader/pipeline.rs` calls `load_deletes()` and builds a
row selection from the delete vector, and `delete_filter.rs` carries a full
equality-delete predicate path. Reading a table that another engine performs
deletes on returns the correct rows.

What remains genuinely absent upstream is **writing** row-level deletes: no
MERGE, UPDATE or DELETE. The read/write asymmetry is the accurate statement, and
is what the README and `icebergr_spec_support()` now say.

### 8c. The name, not just the licence (adds to §2)

The licence question (§2) was the one originally asked, and Apache-2.0 into
GPL-3 is fine. The **trademark** question is separate and more restrictive; see
§1a. The package is `icebergr`, not `iceberg`.

### Status of the build

`iceberg-rust`'s API was read directly from the pinned upstream source, and every
call used in `src/rust/` was checked against it: `MemoryCatalogBuilder`,
`RestCatalogBuilder`, `TableScanBuilder`, `Transaction::fast_append`, the
`DataFileWriter` stack, `Reference`/`Datum` predicate construction,
`register_table`, `plan_files`, and `LocalFsStorageFactory`.

That is not the same as compiling it. Nothing in this repository has been built or
run: the container this was written in cannot reach crates.io — so `cargo vendor`
and `cargo build` are both impossible — and R cannot be installed, because the
Ubuntu archive and every CRAN mirror are blocked by the egress policy. See §6.

CI is therefore the first real verification, and `.github/workflows/R-CMD-check.yaml`
is built for that job: `cargo fmt`/`clippy`/`check` for fast Rust feedback,
`R CMD check` on Linux, macOS and Windows, and a separate vendored offline build
that reproduces the CRAN path and reports the real `vendor.tar.xz` size —
replacing the 35–60 MB estimate in §4a with a measurement. Expect the first runs
to be red.

### 8d. The vendored size, measured (replaces the estimate in §4a)

§4a estimated 35–60 MB and said so was an extrapolation. The measurement, from
`tools/vendor.R` against the pinned `Cargo.lock`:

| | |
| --- | --- |
| Crates a default install compiles | **308** |
| Crates in `vendor.tar.xz` | **442** |
| Vendor tree, uncompressed | 370.8 MB, pruned to 343.5 MB |
| `vendor.tar.xz` | **31.3 MB** |

So the estimate was high but the right order of magnitude, and the conclusion in
§4d stands: this is ~2.3× the largest exception CRAN has granted, and the request
has to be made explicitly.

Two findings that were not visible before it could be measured:

- **The vendor tree carries 134 crates the default build never compiles** — the
  AWS Glue and S3 backends behind the non-default Cargo features. They cannot
  simply be pruned: cargo resolves the *whole* lock graph before it selects
  features, so an offline build fails at resolution ("no matching package named
  `aws-sdk-glue`") if any locked package is absent from the vendor directory.
  Confirmed by removing them and re-running resolution.
- **Removing them from the manifest outright buys almost nothing.** Measured by
  vendoring from a stripped manifest: 442 crates and 31.3 MB become 347 crates
  and 28 MB. `aws-lc-sys` and `aws-sdk-glue` are 87 MB of the *uncompressed*
  tree, but they are largely generated code and xz compresses them to almost
  nothing. Giving up two documented backends for 10% of the archive is not a
  trade worth making, so the features stay.

The lever that is left, if CRAN declines the size, is the dependency itself
rather than the packaging of it.

### 8e. `cargo check` needs R, and R on the PATH (adds to §6)

§6 recorded that nothing could be compiled. It can now, and one detail is worth
writing down because the failure is opaque: `extendr-api`'s build script reads
`DEP_R_R_VERSION_MAJOR`, which `extendr-ffi` only emits if it can find R. Setting
`R_HOME` alone is not enough — `extendr-ffi` also needs `R_INCLUDE_DIR`, or `R`
itself on the `PATH` to ask. Without them it warns, emits nothing, and
`extendr-api` panics with a bare `called Result::unwrap() on an Err value:
NotPresent`. Worse, cargo caches that build-script run, so fixing the environment
is not enough on its own: `cargo clean -p extendr-ffi -p extendr-api` is needed
to re-run it.
