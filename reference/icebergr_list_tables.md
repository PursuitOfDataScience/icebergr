# List tables in a namespace

List tables in a namespace

## Usage

``` r
icebergr_list_tables(catalog, namespace)
```

## Arguments

- catalog:

  An `icebergr_catalog` from
  [`icebergr_catalog()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_catalog.md).

- namespace:

  The namespace to list. Accepts `"db"` or `c("a", "b")`.

## Value

A character vector of table names, without the namespace prefix.

## Examples

``` r
warehouse <- tempfile("warehouse")
dir.create(warehouse)
catalog <- icebergr_catalog("memory", warehouse = warehouse)
# A namespace has to exist before it can hold tables.
icebergr_create_namespace(catalog, "db")
icebergr_list_tables(catalog, "db")
#> character(0)
```
