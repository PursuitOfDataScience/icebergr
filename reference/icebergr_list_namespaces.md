# List namespaces in a catalog

List namespaces in a catalog

## Usage

``` r
icebergr_list_namespaces(catalog, parent = NULL)
```

## Arguments

- catalog:

  An `icebergr_catalog` from
  [`icebergr_catalog()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_catalog.md).

- parent:

  Optional parent namespace, to list only its children. Accepts `"a.b"`
  or `c("a", "b")`.

## Value

A character vector of namespaces, dot-separated when nested.

## Examples

``` r
warehouse <- tempfile("warehouse")
dir.create(warehouse)
catalog <- icebergr_catalog("memory", warehouse = warehouse)
icebergr_list_namespaces(catalog)
#> character(0)
```
