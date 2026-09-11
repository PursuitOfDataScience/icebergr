# What this build of icebergr supports

Reports the supported Iceberg spec versions and a feature-by-feature
matrix, resolved against the optional Cargo features this particular
binary was compiled with. Checking here is more reliable than inferring
from the documentation, because optional features change what is
available.

## Usage

``` r
icebergr_spec_support()
```

## Value

A list with class `icebergr_spec_support`:

- `iceberg_rust_version`:

  The pinned `iceberg-rust` version.

- `arrow_version`:

  The version of the Rust `arrow` crate the interchange layer was built
  against.

- `spec_versions`:

  Iceberg table spec versions that can be read and written.

- `catalogs`:

  Catalog types available in this build.

- `cargo_features`:

  Optional Cargo features compiled in.

- `features`:

  A tibble of `feature`, `supported` and `reason`. `supported` is
  `TRUE`, `FALSE`, or `NA` for something this build supports only in
  part, with `reason` saying which part. A feature that depends on an
  optional Cargo feature is resolved against this build, so it is `TRUE`
  or `FALSE` here and never `NA`.

## Examples

``` r
support <- icebergr_spec_support()
support
#> <icebergr_spec_support>
#>   iceberg-rust:   0.10.0
#>   arrow (Rust):   58.4
#>   spec versions:  v1, v2
#>   catalogs:       rest, memory
#>   cargo features: <none>
#> 
#>   Supported (22):
#>     + Read table (Arrow)
#>     + Predicate pushdown
#>     + Projection pushdown
#>     + Row group pruning
#>     + Snapshot time travel
#>     + Timestamp time travel
#>     + Snapshot history
#>     + Append writes
#>     + Create table
#>     + Create namespace
#>     + Register existing table
#>     + REST catalog
#>     + In-process memory catalog
#>     + Read positional deletes
#>     + Read equality deletes
#>     + Nested types (read/write)
#>     + Decimal predicates
#>     + Nanosecond timestamps
#>     + Table properties (read)
#>     + Read a partitioned table
#>     + Spec v1 tables
#>     + Spec v2 tables
#> 
#>   Partial (1):
#>     ~ Spec v3 tables - Metadata is parsed, but v3 features (row lineage,
#>         deletion vectors) are not exposed
#> 
#>   Not supported (16):
#>     - AWS Glue catalog - Requires the optional 'glue' Cargo feature
#>     - Object storage (S3) - Requires the optional 's3' Cargo feature
#>     - Nested field pushdown - iceberg-rust cannot plan a scan filtered or
#>         projected on a nested field; read the parent column and filter in R
#>     - Table properties (write) - Needs an update_properties transaction; out of
#>         scope for this version of icebergr
#>     - Hadoop/filesystem catalog - Not implemented in iceberg-rust; use type =
#>         'memory'
#>     - Row limit pushdown - iceberg-rust has no row limit in its scan API; limit
#>         is applied after the scan
#>     - Row-level deletes (write) - iceberg-rust 0.10.0 can write an equality
#>         delete file but its transaction API has no action that commits one, so
#>         there is no path to a snapshot
#>     - MERGE / upsert - Needs row-level deletes plus an overwrite, neither of
#>         which iceberg-rust 0.10.0 can commit
#>     - Overwrite writes - iceberg-rust 0.10.0 has no overwrite or rewrite
#>         transaction action; fast_append is the only way to add files
#>     - Schema evolution - Out of scope for this version of icebergr
#>     - Partitioned table creation - Out of scope for this version of icebergr
#>     - Append to a partitioned table - An append would have to compute a
#>         partition value per row, which this version does not do; it is refused
#>         before anything is written
#>     - Partition evolution - Out of scope for this version of icebergr
#>     - Compaction / maintenance - Compaction needs a rewrite action iceberg-rust
#>         0.10.0 does not have. Snapshot expiry it does have, and that one is out
#>         of scope for this version of icebergr
#>     - dbplyr lazy verbs - Out of scope for this version of icebergr
#>     - Table encryption - Not exposed by this version of icebergr

# Check a capability before relying on it.
features <- support$features
features[features$feature == "MERGE / upsert", ]
#> # A tibble: 1 × 3
#>   feature        supported reason                                               
#>   <chr>          <lgl>     <chr>                                                
#> 1 MERGE / upsert FALSE     Needs row-level deletes plus an overwrite, neither o…
```
