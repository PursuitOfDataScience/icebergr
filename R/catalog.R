# Catalog connections.
#
# Credentials are read from the environment and never taken as arguments. An
# argument holding a bearer token ends up in the script that called it, in
# .Rhistory, and in any knitr cache of the chunk that ran it; an environment
# variable does not.

# Environment variable -> Iceberg catalog property.
credential_vars <- c(
  ICEBERGR_REST_TOKEN = "token",
  ICEBERGR_REST_CREDENTIAL = "credential",
  ICEBERGR_REST_OAUTH2_SERVER_URI = "oauth2-server-uri",
  ICEBERGR_REST_SCOPE = "scope",
  ICEBERGR_S3_ACCESS_KEY_ID = "s3.access-key-id",
  ICEBERGR_S3_SECRET_ACCESS_KEY = "s3.secret-access-key",
  ICEBERGR_S3_SESSION_TOKEN = "s3.session-token",
  ICEBERGR_S3_REGION = "s3.region",
  ICEBERGR_S3_ENDPOINT = "s3.endpoint"
)

# Standard AWS variables, consulted when the icebergr-specific ones are unset so
# that an already-configured AWS environment simply works.
aws_fallbacks <- c(
  AWS_ACCESS_KEY_ID = "s3.access-key-id",
  AWS_SECRET_ACCESS_KEY = "s3.secret-access-key",
  AWS_SESSION_TOKEN = "s3.session-token",
  AWS_REGION = "s3.region",
  AWS_DEFAULT_REGION = "s3.region"
)

# Property names that should never be typed into a script.
secret_props <- c(
  "token", "credential", "s3.access-key-id", "s3.secret-access-key",
  "s3.session-token", "gcs.oauth2.token", "adls.sas-token",
  "adls.connection-string"
)

#' @noRd
properties_from_env <- function() {
  out <- list()

  for (var in names(credential_vars)) {
    value <- Sys.getenv(var, unset = "")
    if (nzchar(value)) out[[credential_vars[[var]]]] <- value
  }

  for (var in names(aws_fallbacks)) {
    prop <- aws_fallbacks[[var]]
    if (!is.null(out[[prop]])) next
    value <- Sys.getenv(var, unset = "")
    if (nzchar(value)) out[[prop]] <- value
  }

  out
}

#' Connect to an Iceberg catalog
#'
#' @param type Catalog type. `"rest"` for an Iceberg REST catalog, `"memory"` for
#'   an in-process catalog over a local warehouse directory, `"glue"` for AWS
#'   Glue.
#'
#'   There is deliberately no `"hadoop"` option: `iceberg-rust` does not
#'   implement a Hadoop or filesystem catalog. Use `type = "memory"` with
#'   `warehouse` for a table on local disk.
#' @param uri Catalog URI. Required for `type = "rest"`, ignored otherwise.
#' @param warehouse Warehouse location. A directory for `type = "memory"`; for
#'   REST catalogs, the warehouse name or location the server expects.
#' @param ... Further catalog properties, passed through to `iceberg-rust` as
#'   name-value pairs. Use this for non-secret configuration such as
#'   `"s3.endpoint"` or `"rest.signing-region"`.
#' @param storage Storage backend. `"auto"` infers it from `warehouse`,
#'   `"local"` forces the local filesystem, `"s3"` forces object storage. S3
#'   requires the package to have been compiled with the `s3` Cargo feature.
#' @param name A label for the connection, used in error messages.
#'
#' @section Credentials:
#' Credentials are read from environment variables, never from arguments:
#'
#' \describe{
#'   \item{`ICEBERGR_REST_TOKEN`}{Bearer token for a REST catalog.}
#'   \item{`ICEBERGR_REST_CREDENTIAL`}{OAuth2 client credential.}
#'   \item{`ICEBERGR_REST_OAUTH2_SERVER_URI`}{OAuth2 token endpoint.}
#'   \item{`ICEBERGR_REST_SCOPE`}{OAuth2 scope.}
#'   \item{`ICEBERGR_S3_ACCESS_KEY_ID`, `ICEBERGR_S3_SECRET_ACCESS_KEY`,
#'     `ICEBERGR_S3_SESSION_TOKEN`}{Object storage credentials. The standard
#'     `AWS_*` variables are used as a fallback.}
#' }
#'
#' Catalog properties are never printed, logged or included in error messages.
#' A credential property passed through `...` anyway is accepted but warned
#' about, since a script is the one place it should not be.
#'
#' @return An `icebergr_catalog` object.
#'
#' @examples
#' # A local warehouse needs no catalog server and no credentials.
#' warehouse <- tempfile("warehouse")
#' dir.create(warehouse)
#' catalog <- icebergr_catalog("memory", warehouse = warehouse)
#' catalog
#'
#' \dontrun{
#' # A REST catalog. The token comes from the environment, not from here.
#' Sys.setenv(ICEBERGR_REST_TOKEN = "...")
#' catalog <- icebergr_catalog("rest", uri = "https://catalog.example.com")
#' }
#' @export
icebergr_catalog <- function(type = c("rest", "memory", "glue"),
                             uri = NULL,
                             warehouse = NULL,
                             ...,
                             storage = c("auto", "local", "s3"),
                             name = "icebergr") {
  ensure_rust()

  type <- match.arg(type)
  storage <- match.arg(storage)
  check_string(uri, "uri")
  check_string(warehouse, "warehouse")
  check_string(name, "name", allow_null = FALSE)

  extra <- list(...)
  if (length(extra) && (is.null(names(extra)) || any(!nzchar(names(extra))))) {
    abort("All catalog properties passed through `...` must be named.")
  }

  # Blank counts as absent. `uri = Sys.getenv("MY_CATALOG")` returns "" when the
  # variable is unset, which is the common way to arrive here empty-handed, and
  # it deserves the same answer as a missing argument rather than an error from
  # inside iceberg-rust.
  if (type == "rest" && (is.null(uri) || !nzchar(trimws(uri)))) {
    abort(c(
      "`uri` is required for a REST catalog.",
      i = "For example: icebergr_catalog(\"rest\", uri = \"https://catalog.example.com\")"
    ))
  }

  if (type == "memory") {
    if (is.null(warehouse)) {
      abort(c(
        "`warehouse` is required for a memory catalog.",
        i = "It is the directory the table data lives in."
      ))
    }
    # Slash-separated, because this becomes the root of every table location
    # Iceberg writes into the table's own metadata. On Windows normalizePath()
    # returns backslashes, which iceberg-rust then joins its own "/" onto, giving
    # a mixed "C:\warehouse/db/events" that happens to parse here and is a poor
    # thing to hand another engine reading the same warehouse.
    warehouse <- as_iceberg_location(normalizePath(warehouse, mustWork = FALSE))
    if (!dir.exists(warehouse)) {
      abort(paste0(
        "The warehouse directory does not exist: ",
        encodeString(warehouse, quote = "\"")
      ))
    }
  }

  props <- properties_from_env()
  if (!is.null(uri)) props[["uri"]] <- uri
  if (!is.null(warehouse)) props[["warehouse"]] <- warehouse

  for (key in names(extra)) {
    value <- extra[[key]]
    if (length(value) != 1L || is.na(value)) {
      abort(paste0("Catalog property `", key, "` must be a single non-missing value."))
    }
    if (key %in% secret_props) {
      env_var <- names(credential_vars)[match(key, credential_vars)]
      warn(c(
        paste0("Passing ", encodeString(key, quote = "\""), " as an argument risks leaking it."),
        i = "It will be visible in your script, your .Rhistory and any knitr cache.",
        i = if (!is.na(env_var)) {
          paste0("Set the ", env_var, " environment variable instead.")
        } else {
          "Set it in the environment instead."
        }
      ))
    }
    props[[key]] <- as.character(value)
  }

  # A catalog with no properties at all is legitimate (a REST catalog whose
  # server is configured elsewhere). names() and unlist() both give NULL for an
  # empty list, and Rust wants a character vector, so normalise here.
  ptr <- rs_catalog_connect(
    kind = type,
    name = name,
    storage = storage,
    keys = as.character(names(props)),
    values = as.character(unlist(props, use.names = FALSE))
  )

  structure(
    list(ptr = ptr, type = type, name = name, uri = uri, warehouse = warehouse),
    class = "icebergr_catalog"
  )
}

#' @noRd
check_catalog <- function(x, call = rlang::caller_env()) {
  if (!inherits(x, "icebergr_catalog")) {
    abort("`catalog` must be an object created by `icebergr_catalog()`.", call = call)
  }
  check_live_ptr(x$ptr, "catalog", call = call)
  invisible(NULL)
}

#' @noRd
as_namespace <- function(x, arg = "namespace", allow_null = FALSE,
                         call = rlang::caller_env()) {
  # character(0) means the same as NULL: no levels were named. Letting it past
  # here produced an empty level vector that nothing downstream can use --
  # icebergr_create_namespace() reached `seq_len(-1L)` and reported "argument
  # must be coercible to non-negative integer", which names neither the argument
  # nor the mistake.
  if (is.null(x) || !length(x)) {
    if (allow_null) {
      return(character())
    }
    abort(paste0("`", arg, "` is required."), call = call)
  }
  if (!is.character(x) || anyNA(x) || !all(nzchar(x))) {
    abort(paste0("`", arg, "` must be a character vector of namespace levels."), call = call)
  }
  # "a.b" and c("a", "b") mean the same thing. unlist() of an empty list is
  # NULL rather than character(), which Rust would refuse.
  levels <- as.character(unlist(strsplit(x, ".", fixed = TRUE), use.names = FALSE))

  # A doubled separator splits to an empty level, and an empty level is not
  # something a catalog can address: "a..b" would otherwise create the three
  # levels c("a", "", "b"), which lists back as "a." and can never be named
  # again -- parse_identifier() reads "a..b.events" as c("a", "b"). Dropped
  # rather than rejected, for exactly that consistency.
  levels <- levels[nzchar(levels)]

  if (!length(levels) && length(x)) {
    abort(
      paste0(
        "`", arg, "` has no namespace levels: ",
        encodeString(paste(x, collapse = ", "), quote = "\""), "."
      ),
      call = call
    )
  }
  levels
}

#' List namespaces in a catalog
#'
#' @param catalog An `icebergr_catalog` from [icebergr_catalog()].
#' @param parent Optional parent namespace, to list only its children. Accepts
#'   `"a.b"` or `c("a", "b")`.
#'
#' @return A character vector of namespaces, dot-separated when nested.
#'
#' @examples
#' warehouse <- tempfile("warehouse")
#' dir.create(warehouse)
#' catalog <- icebergr_catalog("memory", warehouse = warehouse)
#' icebergr_list_namespaces(catalog)
#' @export
icebergr_list_namespaces <- function(catalog, parent = NULL) {
  check_catalog(catalog)
  rs_list_namespaces(catalog$ptr, as_namespace(parent, "parent", allow_null = TRUE))
}

#' List tables in a namespace
#'
#' @param catalog An `icebergr_catalog` from [icebergr_catalog()].
#' @param namespace The namespace to list. Accepts `"db"` or `c("a", "b")`.
#'
#' @return A character vector of table names, without the namespace prefix.
#'
#' @examples
#' warehouse <- tempfile("warehouse")
#' dir.create(warehouse)
#' catalog <- icebergr_catalog("memory", warehouse = warehouse)
#' # A namespace has to exist before it can hold tables.
#' icebergr_create_namespace(catalog, "db")
#' icebergr_list_tables(catalog, "db")
#' @export
icebergr_list_tables <- function(catalog, namespace) {
  check_catalog(catalog)
  rs_list_tables(catalog$ptr, as_namespace(namespace))
}

#' @export
print.icebergr_catalog <- function(x, ...) {
  cat("<icebergr_catalog>\n")
  cat("  type:      ", x$type, "\n", sep = "")
  cat("  name:      ", x$name, "\n", sep = "")
  if (!is.null(x$uri)) cat("  uri:       ", x$uri, "\n", sep = "")
  if (!is.null(x$warehouse)) cat("  warehouse: ", x$warehouse, "\n", sep = "")
  # Properties are deliberately not shown: they routinely hold credentials.
  invisible(x)
}
