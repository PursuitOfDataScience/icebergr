# What this build supports, reported honestly and programmatically.

# Kept as data rather than prose so that it can be tested, and so that a user can
# check a capability before relying on it instead of discovering the gap at
# runtime.
feature_matrix <- function() {
  tibble::tribble(
    ~feature,                     ~supported, ~reason,
    "Read table (Arrow)",         TRUE,       NA_character_,
    "Predicate pushdown",         TRUE,       NA_character_,
    "Projection pushdown",        TRUE,       NA_character_,
    "Row group pruning",          TRUE,       NA_character_,
    "Snapshot time travel",       TRUE,       NA_character_,
    "Timestamp time travel",      TRUE,       "Resolved in R against snapshot history; iceberg-rust takes only snapshot ids",
    "Snapshot history",           TRUE,       NA_character_,
    "Append writes",              TRUE,       NA_character_,
    "Create table",               TRUE,       "Unpartitioned only",
    "Create namespace",           TRUE,       NA_character_,
    "Register existing table",    TRUE,       NA_character_,
    "REST catalog",               TRUE,       NA_character_,
    "In-process memory catalog",  TRUE,       NA_character_,
    "AWS Glue catalog",           NA,         "Requires the optional 'glue' Cargo feature",
    "Object storage (S3)",        NA,         "Requires the optional 's3' Cargo feature",
    "Read positional deletes",    TRUE,       "Applied by iceberg-rust during the scan",
    "Read equality deletes",      TRUE,       "Applied by iceberg-rust during the scan",
    "Nested types (read/write)",  TRUE,       "struct, list and map round trip; a struct arrives as a data frame column",
    "Nested field pushdown",      FALSE,      "iceberg-rust cannot plan a scan filtered or projected on a nested field; read the parent column and filter in R",
    "Table properties (read)",    TRUE,       NA_character_,
    "Table properties (write)",   FALSE,      "Needs an update_properties transaction; out of scope for icebergr 0.1.0",
    "Hadoop/filesystem catalog",  FALSE,      "Not implemented in iceberg-rust; use type = 'memory'",
    "Row limit pushdown",         FALSE,      "iceberg-rust has no row limit in its scan API; limit is applied after the scan",
    "Row-level deletes (write)",  FALSE,      "Not implemented in iceberg-rust",
    "MERGE / upsert",             FALSE,      "Not implemented in iceberg-rust",
    "Overwrite writes",           FALSE,      "Out of scope for icebergr 0.1.0",
    "Schema evolution",           FALSE,      "Out of scope for icebergr 0.1.0",
    "Partitioned table creation", FALSE,      "Out of scope for icebergr 0.1.0",
    "Partition evolution",        FALSE,      "Out of scope for icebergr 0.1.0",
    "Compaction / maintenance",   FALSE,      "Out of scope for icebergr 0.1.0",
    "dbplyr lazy verbs",          FALSE,      "Out of scope for icebergr 0.1.0",
    "Table encryption",           FALSE,      "Not exposed in icebergr 0.1.0",
    "Spec v1 tables",             TRUE,       NA_character_,
    "Spec v2 tables",             TRUE,       NA_character_,
    "Spec v3 tables",             NA,         "Metadata is parsed, but v3 features (row lineage, deletion vectors) are not exposed"
  )
}

#' What this build of icebergr supports
#'
#' Reports the supported Iceberg spec versions and a feature-by-feature matrix,
#' resolved against the optional Cargo features this particular binary was
#' compiled with. Checking here is more reliable than inferring from the
#' documentation, because optional features change what is available.
#'
#' @return A list with class `icebergr_spec_support`:
#'   \describe{
#'     \item{`iceberg_rust_version`}{The pinned `iceberg-rust` version.}
#'     \item{`arrow_version`}{The version of the Rust `arrow` crate the
#'       interchange layer was built against.}
#'     \item{`spec_versions`}{Iceberg table spec versions that can be read and
#'       written.}
#'     \item{`catalogs`}{Catalog types available in this build.}
#'     \item{`cargo_features`}{Optional Cargo features compiled in.}
#'     \item{`features`}{A tibble of `feature`, `supported` and `reason`.
#'       `supported` is `TRUE`, `FALSE`, or `NA` when it depends on a build
#'       option that is absent here.}
#'   }
#'
#' @examples
#' support <- icebergr_spec_support()
#' support
#'
#' # Check a capability before relying on it.
#' features <- support$features
#' features[features$feature == "MERGE / upsert", ]
#' @export
icebergr_spec_support <- function() {
  info <- build_info()

  features <- feature_matrix()

  # Resolve the build-dependent rows against what is actually compiled in.
  compiled <- info$features
  features$supported[features$feature == "AWS Glue catalog"] <- "glue" %in% compiled
  features$supported[features$feature == "Object storage (S3)"] <- "s3" %in% compiled

  structure(
    list(
      iceberg_rust_version = info$iceberg_rust_version,
      arrow_version = info$arrow_version,
      spec_versions = c(1L, 2L),
      catalogs = info$catalogs,
      cargo_features = compiled,
      features = features
    ),
    class = "icebergr_spec_support"
  )
}

#' @export
print.icebergr_spec_support <- function(x, ...) {
  cat("<icebergr_spec_support>\n")
  cat("  iceberg-rust:   ", x$iceberg_rust_version, "\n", sep = "")
  cat("  arrow (Rust):   ", x$arrow_version, "\n", sep = "")
  cat("  spec versions:  ", paste0("v", x$spec_versions, collapse = ", "), "\n", sep = "")
  cat("  catalogs:       ", paste(x$catalogs, collapse = ", "), "\n", sep = "")
  cat("  cargo features: ",
    if (length(x$cargo_features)) paste(x$cargo_features, collapse = ", ") else "<none>",
    "\n",
    sep = ""
  )

  supported <- x$features[isTRUE_vec(x$features$supported), , drop = FALSE]
  unavailable <- x$features[is.na(x$features$supported), , drop = FALSE]
  unsupported <- x$features[isFALSE_vec(x$features$supported), , drop = FALSE]

  cat("\n  Supported (", nrow(supported), "):\n", sep = "")
  for (f in supported$feature) cat("    + ", f, "\n", sep = "")

  if (nrow(unavailable)) {
    cat("\n  Not in this build (", nrow(unavailable), "):\n", sep = "")
    for (i in seq_len(nrow(unavailable))) {
      cat("    ? ", unavailable$feature[[i]], " - ", unavailable$reason[[i]], "\n", sep = "")
    }
  }

  cat("\n  Not supported (", nrow(unsupported), "):\n", sep = "")
  for (i in seq_len(nrow(unsupported))) {
    cat("    - ", unsupported$feature[[i]], " - ", unsupported$reason[[i]], "\n", sep = "")
  }

  invisible(x)
}

#' @noRd
isTRUE_vec <- function(x) !is.na(x) & x

#' @noRd
isFALSE_vec <- function(x) !is.na(x) & !x
