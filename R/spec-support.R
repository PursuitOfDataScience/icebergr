# What this build supports, reported honestly and programmatically.

# Kept as data rather than prose so that it can be tested, and so that a user can
# check a capability before relying on it instead of discovering the gap at
# runtime.
feature_matrix <- function() {
  tibble::tribble(
    ~feature, ~supported, ~reason,
    "Read table (Arrow)", TRUE, NA_character_,
    "Predicate pushdown", TRUE, NA_character_,
    "Projection pushdown", TRUE, NA_character_,
    "Row group pruning", TRUE, NA_character_,
    "Snapshot time travel", TRUE, NA_character_,
    "Timestamp time travel", TRUE, "Resolved in R against snapshot history; iceberg-rust takes only snapshot ids",
    "Snapshot history", TRUE, NA_character_,
    "Append writes", TRUE, NA_character_,
    "Create table", TRUE, "Unpartitioned only; sort order, initial table properties and format version are settable upstream but not exposed here",
    "Create namespace", TRUE, NA_character_,
    "Register existing table", TRUE, NA_character_,
    "REST catalog", TRUE, NA_character_,
    "In-process memory catalog", TRUE, NA_character_,
    "AWS Glue catalog", NA, "Requires the optional 'glue' Cargo feature",
    "Object storage (S3)", NA, "Requires the optional 's3' Cargo feature",
    "Read positional deletes", TRUE, "Applied by iceberg-rust during the scan",
    "Read equality deletes", TRUE, "Applied by iceberg-rust during the scan, except when the equality field is a list or a map column, which it refuses",
    "Nested types (read/write)", TRUE, "struct and list round trip; a struct arrives as a data frame column. A map column can be created, but writing map values needs the 'arrow' package: nanoarrow cannot build a map array on its own",
    "Decimal predicates", TRUE, "Row-level selection is disabled for these scans; iceberg-rust 0.10.0 drops every row of an ordering comparison on a decimal. File and row group pruning still apply",
    "Nanosecond timestamps", TRUE, "Read, written and filtered, but R's POSIXct is a double of seconds, so sub-microsecond precision is lost and nanoarrow warns on every such read",
    "Nested field pushdown", FALSE, "iceberg-rust cannot plan a scan filtered or projected on a nested field; read the parent column and filter in R",
    "Table properties (read)", TRUE, NA_character_,
    "Table properties (write)", FALSE, "Needs an update_properties transaction; out of scope for icebergr 0.1.0",
    "Hadoop/filesystem catalog", FALSE, "Not implemented in iceberg-rust; use type = 'memory'",
    "Row limit pushdown", FALSE, "iceberg-rust has no row limit in its scan API; limit is applied after the scan",
    "Row-level deletes (write)", FALSE, "iceberg-rust 0.10.0 can write an equality delete file but its transaction API has no action that commits one, so there is no path to a snapshot",
    "MERGE / upsert", FALSE, "Needs row-level deletes plus an overwrite, neither of which iceberg-rust 0.10.0 can commit",
    "Overwrite writes", FALSE, "iceberg-rust 0.10.0 has no overwrite or rewrite transaction action; fast_append is the only way to add files",
    "Schema evolution", FALSE, "Out of scope for icebergr 0.1.0",
    "Partitioned table creation", FALSE, "Out of scope for icebergr 0.1.0",
    "Read a partitioned table", TRUE, "The spec is reported by icebergr_partitions() and the data reads normally",
    "Append to a partitioned table", FALSE, "An append would have to compute a partition value per row, which this version does not do; it is refused before anything is written",
    "Partition evolution", FALSE, "Out of scope for icebergr 0.1.0",
    "Compaction / maintenance", FALSE, "Compaction needs a rewrite action iceberg-rust 0.10.0 does not have. Snapshot expiry it does have, and that one is out of scope for icebergr 0.1.0",
    "dbplyr lazy verbs", FALSE, "Out of scope for icebergr 0.1.0",
    "Table encryption", FALSE, "Not exposed in icebergr 0.1.0",
    "Spec v1 tables", TRUE, NA_character_,
    "Spec v2 tables", TRUE, NA_character_,
    "Spec v3 tables", NA, "Metadata is parsed, but v3 features (row lineage, deletion vectors) are not exposed"
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
#'       `supported` is `TRUE`, `FALSE`, or `NA` for something this build
#'       supports only in part, with `reason` saying which part. A feature that
#'       depends on an optional Cargo feature is resolved against this build, so
#'       it is `TRUE` or `FALSE` here and never `NA`.}
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
  # Not "not in this build": the two rows that really do depend on a build option
  # were resolved to TRUE or FALSE above, so everything still NA by here is a
  # feature this build has in part -- spec v3, whose metadata parses while its own
  # features are not exposed. Filing that under "not in this build" said the
  # opposite of what is true.
  partial <- x$features[is.na(x$features$supported), , drop = FALSE]
  unsupported <- x$features[isFALSE_vec(x$features$supported), , drop = FALSE]

  cat("\n  Supported (", nrow(supported), "):\n", sep = "")
  for (f in supported$feature) cat("    + ", f, "\n", sep = "")

  if (nrow(partial)) {
    cat("\n  Partial (", nrow(partial), "):\n", sep = "")
    for (i in seq_len(nrow(partial))) {
      cat_feature("~", partial$feature[[i]], partial$reason[[i]])
    }
  }

  cat("\n  Not supported (", nrow(unsupported), "):\n", sep = "")
  for (i in seq_len(nrow(unsupported))) {
    cat_feature("-", unsupported$feature[[i]], unsupported$reason[[i]])
  }

  invisible(x)
}

#' One feature and its reason, wrapped to the terminal
#'
#' The reasons are sentences, not labels -- several run past 140 characters, which
#' a terminal wraps wherever it happens to land, mid-word and without indent.
#' Wrapping here keeps the continuation aligned under the feature it belongs to.
#' @noRd
cat_feature <- function(marker, feature, reason) {
  entry <- if (is.na(reason) || !nzchar(reason)) {
    paste(marker, feature)
  } else {
    paste0(marker, " ", feature, " - ", reason)
  }
  # A floor of 40 so a very narrow terminal still produces something readable
  # rather than one word per line.
  width <- max(40L, getOption("width", 80L))
  writeLines(strwrap(entry, width = width, initial = "    ", prefix = "        "))
  invisible(NULL)
}

#' @noRd
isTRUE_vec <- function(x) !is.na(x) & x

#' @noRd
isFALSE_vec <- function(x) !is.na(x) & !x
