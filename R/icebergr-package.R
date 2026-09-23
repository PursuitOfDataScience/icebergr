#' @description
#' A native Apache Iceberg client for R. Rather than reaching Iceberg through a
#' query engine such as DuckDB, icebergr talks to it directly, through
#' `iceberg-rust`, and hands you the table itself: its snapshots, its schema as of
#' each of them, its scan plan, and appends that commit new snapshots.
#'
#' @section Getting started:
#' Connect to a catalog with [icebergr_catalog()], open a table with
#' [icebergr_table()], and read it with [icebergr_scan()] and
#' [icebergr_collect()]. See `vignette("getting-started", package = "icebergr")`.
#'
#' @section What is supported:
#' A deliberately narrow subset: catalog discovery, schema and partition
#' inspection, reads with predicate and projection pushdown, snapshot time
#' travel, and append-only writes. Row-level deletes, MERGE, schema evolution
#' and partition evolution are not supported, and several of those are absent
#' from `iceberg-rust` too. [icebergr_spec_support()] reports the full matrix for
#' your specific build.
#'
#' @section Credentials:
#' Credentials are read from environment variables and are never accepted as
#' function arguments, so they cannot end up in a saved script or an `.Rhistory`
#' file. See `vignette("catalog-configuration", package = "icebergr")`.
#'
#' @section Trademarks:
#' Apache, Apache Iceberg and Iceberg are trademarks of The Apache Software
#' Foundation. icebergr is a community package and is not affiliated with,
#' sponsored by or endorsed by the ASF.
#'
#' @keywords internal
#' @useDynLib icebergr, .registration = TRUE
#' @importFrom rlang abort
#' @importFrom rlang warn
"_PACKAGE"
