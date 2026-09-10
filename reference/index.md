# Package index

## Connecting

A catalog is the thing that knows where tables are. Credentials come
from the environment, never from arguments.

- [`icebergr_catalog()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_catalog.md)
  : Connect to an Iceberg catalog
- [`icebergr_list_namespaces()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_list_namespaces.md)
  : List namespaces in a catalog
- [`icebergr_list_tables()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_list_tables.md)
  : List tables in a namespace
- [`icebergr_create_namespace()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_create_namespace.md)
  : Create a namespace

## Table handles

A handle is bound to one snapshot, which is what makes two scans off it
agree.
[`icebergr_reload()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_reload.md)
is how you opt in to newer commits.

- [`icebergr_table()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_table.md)
  : Open an Iceberg table
- [`icebergr_table_exists()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_table_exists.md)
  : Whether a table exists in a catalog
- [`icebergr_reload()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_reload.md)
  : Re-read a table's metadata from its catalog

## Reading

[`icebergr_scan()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_scan.md)
pushes the filter and the column list down into `iceberg-rust`;
[`icebergr_scan_plan()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_scan_plan.md)
shows what survived before any data file is opened.

- [`icebergr_scan()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_scan.md)
  : Scan an Iceberg table
- [`icebergr_scan_plan()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_scan_plan.md)
  : Inspect the file plan for a scan
- [`icebergr_collect()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_collect.md)
  [`as.data.frame(`*`<icebergr_scan>`*`)`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_collect.md)
  [`as.data.frame(`*`<icebergr_table>`*`)`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_collect.md)
  : Materialise a scan or a table

## Metadata

- [`icebergr_schema()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_schema.md)
  : The schema of an Iceberg table
- [`icebergr_partitions()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_partitions.md)
  : The partition specification of an Iceberg table
- [`icebergr_properties()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_properties.md)
  : The properties of an Iceberg table
- [`icebergr_snapshots()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_snapshots.md)
  : Snapshot history of an Iceberg table

## Writing

Appends, table and namespace creation, and registering a table another
engine wrote. What this version will not write, it refuses before
anything reaches the warehouse.

- [`icebergr_append()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_append.md)
  : Append rows to an Iceberg table
- [`icebergr_create_table()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_create_table.md)
  : Create an Iceberg table
- [`icebergr_register_table()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_register_table.md)
  : Register an existing table with a catalog

## Knowing the boundary

Which parts of the Iceberg spec this build supports, and for each gap,
whether it is missing here or missing in `iceberg-rust`.

- [`icebergr_spec_support()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_spec_support.md)
  : What this build of icebergr supports

## Examples and package overview

- [`icebergr_example_table()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_example_table.md)
  : A small Iceberg table for offline examples and tests
- [`icebergr`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr-package.md)
  [`icebergr-package`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr-package.md)
  : icebergr: Read and Write 'Apache Iceberg' Tables
