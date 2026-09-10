# Create an Iceberg table

The table's schema is taken from `data`, so an existing data frame is
enough to define one. Iceberg field ids are assigned automatically,
since a data frame has no concept of them.

## Usage

``` r
icebergr_create_table(catalog, table, data, location = NULL)
```

## Arguments

- catalog:

  An `icebergr_catalog` from
  [`icebergr_catalog()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_catalog.md).

- table:

  A table identifier, `"namespace.table"`. The namespace must already
  exist; see
  [`icebergr_create_namespace()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_create_namespace.md).

- data:

  A data frame whose columns define the schema. No rows are written;
  only the column names and types are used. An Arrow schema is also
  accepted.

- location:

  Where to store the table. `NULL` lets the catalog decide, which is
  almost always what you want.

## Value

An `icebergr_table` handle for the new, empty table.

## Details

The table is created unpartitioned. Partitioned table creation, like
partition evolution, is out of scope for this version; see
[`icebergr_spec_support()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_spec_support.md).

## Examples

``` r
warehouse <- tempfile("warehouse")
dir.create(warehouse)
catalog <- icebergr_catalog("memory", warehouse = warehouse)
icebergr_create_namespace(catalog, "db")

tbl <- icebergr_create_table(
  catalog, "db.events",
  data.frame(id = integer(), amount = double(), label = character())
)
icebergr_schema(tbl)
#> # A tibble: 3 × 5
#>   field_id name   type   required doc  
#>      <int> <chr>  <chr>  <lgl>    <chr>
#> 1        1 id     int    FALSE    NA   
#> 2        2 amount double FALSE    NA   
#> 3        3 label  string FALSE    NA   
```
