# Create a namespace

Create a namespace

## Usage

``` r
icebergr_create_namespace(catalog, namespace)
```

## Arguments

- catalog:

  An `icebergr_catalog` from
  [`icebergr_catalog()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_catalog.md).

- namespace:

  The namespace to create. Accepts `"db"` or `c("a", "b")`.

## Value

`catalog`, invisibly.

## Examples

``` r
warehouse <- tempfile("warehouse")
dir.create(warehouse)
catalog <- icebergr_catalog("memory", warehouse = warehouse)
icebergr_create_namespace(catalog, "db")
icebergr_list_namespaces(catalog)
#> [1] "db"
```
