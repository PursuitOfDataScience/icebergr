# Re-read a table's metadata from its catalog

A table handle is a snapshot of the metadata as it was when the handle
was opened, which is what makes a read consistent. That also means a
handle never sees a commit made after it:
[`icebergr_append()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_append.md)
hands back an updated handle for your own writes, but a commit from
another session, process or engine is invisible until the metadata is
read again. This is how to do that without going back to the catalog by
name.

## Usage

``` r
icebergr_reload(tbl)
```

## Arguments

- tbl:

  An `icebergr_table` from
  [`icebergr_table()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_table.md).

## Value

A new `icebergr_table` handle seeing the table's current state. The
handle passed in is unchanged, so reassign it:
`tbl <- icebergr_reload(tbl)`.

## Examples

``` r
warehouse <- tempfile("warehouse")
dir.create(warehouse)
catalog <- icebergr_catalog("memory", warehouse = warehouse)
icebergr_create_namespace(catalog, "db")
events <- data.frame(id = 1:3L)
tbl <- icebergr_create_table(catalog, "db.events", events)

# A second handle on the same table, as another session would hold.
stale <- icebergr_table(catalog, "db.events")
tbl <- icebergr_append(tbl, events)

# The second handle still sees the table as it was when it was opened.
nrow(icebergr_collect(stale))
#> [1] 0
nrow(icebergr_collect(icebergr_reload(stale)))
#> [1] 3
```
