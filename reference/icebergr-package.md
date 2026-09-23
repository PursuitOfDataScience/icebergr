# icebergr: Read and Write 'Apache Iceberg' Tables

A native Apache Iceberg client for R. Rather than reaching Iceberg
through a query engine such as DuckDB, icebergr talks to it directly,
through `iceberg-rust`, and hands you the table itself: its snapshots,
its schema as of each of them, its scan plan, and appends that commit
new snapshots.

## Getting started

Connect to a catalog with
[`icebergr_catalog()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_catalog.md),
open a table with
[`icebergr_table()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_table.md),
and read it with
[`icebergr_scan()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_scan.md)
and
[`icebergr_collect()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_collect.md).
See
[`vignette("getting-started", package = "icebergr")`](https://pursuitofdatascience.github.io/icebergr/articles/getting-started.md).

## What is supported

A deliberately narrow subset: catalog discovery, schema and partition
inspection, reads with predicate and projection pushdown, snapshot time
travel, and append-only writes. Row-level deletes, MERGE, schema
evolution and partition evolution are not supported, and several of
those are absent from `iceberg-rust` too.
[`icebergr_spec_support()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_spec_support.md)
reports the full matrix for your specific build.

## Credentials

Credentials are read from environment variables and are never accepted
as function arguments, so they cannot end up in a saved script or an
`.Rhistory` file. See
[`vignette("catalog-configuration", package = "icebergr")`](https://pursuitofdatascience.github.io/icebergr/articles/catalog-configuration.md).

## Trademarks

Apache, Apache Iceberg and Iceberg are trademarks of The Apache Software
Foundation. icebergr is a community package and is not affiliated with,
sponsored by or endorsed by the ASF.

## See also

Useful links:

- <https://pursuitofdatascience.github.io/icebergr/>

- <https://github.com/PursuitOfDataScience/icebergr>

- Report bugs at
  <https://github.com/PursuitOfDataScience/icebergr/issues>

## Author

**Maintainer**: Youzhi Yu <yuyouzhi666@icloud.com>

Authors:

- Youzhi Yu <yuyouzhi666@icloud.com>

Other contributors:

- The Apache Software Foundation (iceberg-rust, bundled under Apache
  License 2.0) \[copyright holder\]
