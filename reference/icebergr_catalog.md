# Connect to an Iceberg catalog

Connect to an Iceberg catalog

## Usage

``` r
icebergr_catalog(
  type = c("rest", "memory", "glue"),
  uri = NULL,
  warehouse = NULL,
  ...,
  storage = c("auto", "local", "s3"),
  name = "icebergr"
)
```

## Arguments

- type:

  Catalog type. `"rest"` for an Iceberg REST catalog, `"memory"` for an
  in-process catalog over a local warehouse directory, `"glue"` for AWS
  Glue.

  There is deliberately no `"hadoop"` option: `iceberg-rust` does not
  implement a Hadoop or filesystem catalog. Use `type = "memory"` with
  `warehouse` for a table on local disk.

- uri:

  Catalog URI. Required for `type = "rest"`, ignored otherwise.

- warehouse:

  Warehouse location. A directory for `type = "memory"`; for REST
  catalogs, the warehouse name or location the server expects.

- ...:

  Further catalog properties, passed through to `iceberg-rust` as
  name-value pairs. Use this for non-secret configuration such as
  `"s3.endpoint"` or `"rest.signing-region"`.

- storage:

  Storage backend. `"auto"` infers it from `warehouse`, `"local"` forces
  the local filesystem, `"s3"` forces object storage. S3 requires the
  package to have been compiled with the `s3` Cargo feature.

- name:

  A label for the connection, used in error messages.

## Value

An `icebergr_catalog` object.

## Credentials

Credentials are read from environment variables, never from arguments:

- `ICEBERGR_REST_TOKEN`:

  Bearer token for a REST catalog.

- `ICEBERGR_REST_CREDENTIAL`:

  OAuth2 client credential.

- `ICEBERGR_REST_OAUTH2_SERVER_URI`:

  OAuth2 token endpoint.

- `ICEBERGR_REST_SCOPE`:

  OAuth2 scope.

- `ICEBERGR_S3_ACCESS_KEY_ID`, `ICEBERGR_S3_SECRET_ACCESS_KEY`,
  `ICEBERGR_S3_SESSION_TOKEN`:

  Object storage credentials. The standard `AWS_*` variables are used as
  a fallback.

Catalog properties are never printed, logged or included in error
messages. A credential property passed through `...` anyway is accepted
but warned about, since a script is the one place it should not be.

## Examples

``` r
# A local warehouse needs no catalog server and no credentials.
warehouse <- tempfile("warehouse")
dir.create(warehouse)
catalog <- icebergr_catalog("memory", warehouse = warehouse)
catalog
#> <icebergr_catalog>
#>   type:      memory
#>   name:      icebergr
#>   warehouse: /tmp/RtmpATkEDd/warehouse29967be31ecc

if (FALSE) { # \dontrun{
# A REST catalog. The token comes from the environment, not from here.
Sys.setenv(ICEBERGR_REST_TOKEN = "...")
catalog <- icebergr_catalog("rest", uri = "https://catalog.example.com")
} # }
```
