# Types: The R, Arrow and Iceberg Correspondence

Data crosses between R and Iceberg over the Arrow C stream interface
(The Apache Software Foundation 2026b): `iceberg-rust` writes Arrow
arrays, `nanoarrow` (Dunnington and Arrow 2026) reads the same memory,
and nothing is serialised in between. Two type systems still have to be
reconciled at each end, and this vignette is about where that
reconciliation is exact and where it is not.

``` r

warehouse <- file.path(tempdir(), "icebergr-types")
dir.create(warehouse, showWarnings = FALSE)
catalog <- icebergr_catalog("memory", warehouse = warehouse)
icebergr_create_namespace(catalog, "t")
```

### What survives unchanged

``` r

plain <- data.frame(
  i = 1L,
  d = 1.5,
  s = "text",
  b = TRUE,
  day = as.Date("2026-07-01"),
  ts = as.POSIXct("2026-07-01 09:00:00", tz = "UTC")
)

tbl <- icebergr_create_table(catalog, "t.plain", plain)
icebergr_schema(tbl)[, c("name", "type")]
#> # A tibble: 6 × 2
#>   name  type       
#>   <chr> <chr>      
#> 1 i     int        
#> 2 d     double     
#> 3 s     string     
#> 4 b     boolean    
#> 5 day   date       
#> 6 ts    timestamptz
```

`integer`, `double`, `character`, `logical`, `Date` and `POSIXct` map
onto `int`, `double`, `string`, `boolean`, `date` and `timestamptz`, and
come back as themselves:

``` r

tbl <- icebergr_append(tbl, plain)
back <- icebergr_collect(tbl)
vapply(back, function(x) class(x)[[1]], character(1))
#>           i           d           s           b         day          ts 
#>   "integer"   "numeric" "character"   "logical"      "Date"   "POSIXct"
identical(back$s, plain$s)
#> [1] TRUE
identical(back$day, plain$day)
#> [1] TRUE
```

A `POSIXct` is normalised to UTC — the instant is preserved, the printed
time zone is not. That is Iceberg’s `timestamptz` semantics, not a lossy
conversion.

### The five that need care

#### `NaN` comes back as `NA`

``` r

nan_tbl <- icebergr_create_table(catalog, "t.nan", data.frame(x = 1.5))
nan_tbl <- icebergr_append(nan_tbl, data.frame(x = c(1.5, NaN, NA)))
icebergr_collect(nan_tbl)$x
#> [1] 1.5  NA  NA
```

R’s `is.na(NaN)` is `TRUE`, so `NaN` is written as a null and reads back
as `NA`. Nothing in the stack distinguishes them on the way out. If the
difference matters, encode it in another column.

#### `factor` comes back as `character`

``` r

fac_tbl <- icebergr_create_table(
  catalog, "t.fac",
  data.frame(g = factor("a", levels = c("a", "b")))
)
fac_tbl <- icebergr_append(fac_tbl, data.frame(g = factor(c("a", "b", "a"))))
str(icebergr_collect(fac_tbl)$g)
#>  chr [1:3] "a" "b" "a"
```

Iceberg has no dictionary type, so the levels have nowhere to live.
Restore them in R with [`factor()`](https://rdrr.io/r/base/factor.html)
and your own level order — which is the honest outcome, because a round
trip that invented a level order would be worse.

#### `long` needs `bit64`

Iceberg’s `long` is 64-bit. An R double holds 53 bits of mantissa, so a
value past $`2^{53}`$ cannot survive as a `numeric`. With `bit64`
installed it comes back exact, at any depth — including inside a
`struct`:

``` r

big <- bit64::as.integer64("9007199254740993") # 2^53 + 1
long_tbl <- icebergr_create_table(catalog, "t.long", data.frame(n = big))
long_tbl <- icebergr_append(long_tbl, data.frame(n = big))

got <- icebergr_collect(long_tbl)$n
class(got)
#> [1] "integer64"
as.character(got)
#> [1] "9007199254740993"
```

``` r

identical(as.character(got), "9007199254740993")
#> [1] TRUE
```

Without `bit64`, Arrow’s `int64` narrows to a `double` and that value
reads back as 9007199254740992. The package does not error on this — it
is Arrow’s documented fallback — so if you handle 64-bit keys, put
`bit64` in your own `Imports`.

#### `timestamp_ns` loses sub-microsecond precision

A nanosecond timestamp is readable, writable and filterable, but a
`POSIXct` is a double of *seconds*, so the bottom digits cannot be
represented. `nanoarrow` warns on every such read: the warning triggers
on the nanosecond count exceeding $`2^{53}`$, which any present-day
instant does, so it appears even when nothing was actually lost.

#### Snapshot ids are `character`

Not a column type, but the same arithmetic. See
[`vignette("time-travel")`](https://pursuitofdatascience.github.io/icebergr/articles/time-travel.md).

### Nested types

`struct` arrives as a data frame column, which is the natural R shape
for it:

``` r

nested <- data.frame(id = 1L)
nested$geo <- data.frame(lat = 41.79, lon = -87.6)

nest_tbl <- icebergr_create_table(catalog, "t.nested", nested)
icebergr_schema(nest_tbl)[, c("name", "type")]
#> # A tibble: 2 × 2
#>   name  type                            
#>   <chr> <chr>                           
#> 1 id    int                             
#> 2 geo   struct<lat: double, lon: double>
```

``` r

nest_tbl <- icebergr_append(nest_tbl, nested)
got <- icebergr_collect(nest_tbl)
class(got$geo)
#> [1] "data.frame"
got$geo$lat
#> [1] 41.79
```

A `list` column round-trips as a
[`vctrs::list_of`](https://vctrs.r-lib.org/reference/list_of.html):

``` r

lst <- data.frame(id = 1L)
lst$tags <- vctrs::list_of(c("a", "b"))

lst_tbl <- icebergr_create_table(catalog, "t.lst", lst)
lst_tbl <- icebergr_append(lst_tbl, lst)
icebergr_collect(lst_tbl)$tags
#> <list_of<character>[1]>
#> [[1]]
#> [1] "a" "b"
```

That nesting survives a columnar layout at all because of Dremel’s
repetition and definition levels (Melnik et al. 2010), which is how
Parquet stores a repeated or optional field one column at a time.

**Iceberg cannot push a filter or a projection *onto* a nested field.**
Read the parent column and subset in R:

``` r

subset(icebergr_collect(nest_tbl), geo$lat > 41)
#> # A tibble: 1 × 2
#>      id geo$lat  $lon
#>   <int>   <dbl> <dbl>
#> 1     1    41.8 -87.6
```

A `map` column can be created, but writing map *values* from R needs the
`arrow` package, because `nanoarrow` cannot build a map array on its
own. If you do,
[`nanoarrow::na_map()`](https://arrow.apache.org/nanoarrow/latest/r/reference/na_type.html)
needs its key type built non-nullable —
`na_map(na_string(nullable = FALSE), …)`.

### Reading the schema rather than guessing it

[`icebergr_schema()`](https://pursuitofdatascience.github.io/icebergr/reference/icebergr_schema.md)
reports Iceberg’s own types, with the field ids that make schema
evolution possible in the format:

``` r

icebergr_schema(nest_tbl)
#> # A tibble: 2 × 5
#>   field_id name  type                             required doc  
#>      <int> <chr> <chr>                            <lgl>    <chr>
#> 1        1 id    int                              FALSE    NA   
#> 2        2 geo   struct<lat: double, lon: double> TRUE     NA
```

Field ids, not names, are what a manifest refers to — which is why
Iceberg can rename a column without rewriting data, and why the Hive
convention could not (The Apache Software Foundation 2026a; Thusoo et
al. 2009).

### Why the bridge is an Arrow bridge

Handing R a pointer to Arrow memory that Rust allocated, with no copy
and no serialisation, is the concrete benefit of the composable-systems
design (Pedreira et al. 2023): the interchange format is the contract,
so neither side needs to know the other’s internals. The R half is
`nanoarrow` (Dunnington and Arrow 2026); the binding itself is `extendr`
(The extendr authors 2026); and the type correspondence above is the
whole of what this package has to get right at the boundary.

## References

Dunnington, Dewey, and Apache Arrow. 2026. *Nanoarrow: Interface to the
’Nanoarrow’ ’c’ Library*.
<https://arrow.apache.org/nanoarrow/latest/r/>.

Melnik, Sergey, Andrey Gubarev, Jing Jing Long, et al. 2010. “Dremel:
Interactive Analysis of Web-Scale Datasets.” *Proceedings of the VLDB
Endowment* 3 (1-2): 330–39. <https://doi.org/10.14778/1920841.1920886>.

Pedreira, Pedro, Orri Erling, Konstantinos Karanasos, et al. 2023. “The
Composable Data Management System Manifesto.” *Proceedings of the VLDB
Endowment* 16 (10): 2679–85. <https://doi.org/10.14778/3603581.3603604>.

The Apache Software Foundation. 2026a. *Apache Iceberg Table Spec*.
Apache Iceberg documentation. <https://iceberg.apache.org/spec/>.

The Apache Software Foundation. 2026b. *The Arrow C Data Interface and C
Stream Interface*. Apache Arrow documentation.
<https://arrow.apache.org/docs/format/CDataInterface.html>.

The extendr authors. 2026. *Extendr: A Safe and User-Friendly R
Extension Interface Using Rust*. <https://extendr.rs/>.

Thusoo, Ashish, Joydeep Sen Sarma, Namit Jain, et al. 2009. “Hive: A
Warehousing Solution over a Map-Reduce Framework.” *Proceedings of the
VLDB Endowment* 2 (2): 1626–29.
<https://doi.org/10.14778/1687553.1687609>.
