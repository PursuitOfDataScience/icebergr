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

# Does this connection actually address object storage?
#
# `storage = "s3"` says so outright, Glue implies it, and an `s3://` warehouse
# is the "auto" case. A REST catalog whose warehouse is a *name* rather than a
# location cannot be classified from here, which is what `storage = "s3"` is
# for.
#' @noRd
uses_object_storage <- function(type, storage, warehouse) {
  if (identical(storage, "s3")) {
    return(TRUE)
  }
  if (identical(storage, "local")) {
    return(FALSE)
  }
  if (identical(type, "glue")) {
    return(TRUE)
  }
  !is.null(warehouse) && grepl("^s3a?://", warehouse, ignore.case = TRUE)
}

# The ICEBERGR_* variables are an explicit instruction and are always honoured.
# The ambient AWS_* ones are not: they are whatever the machine happens to have
# configured, and forwarding them to a catalog that is not object storage hands
# the user's keys to a party with no use for them. Worse, a third-party REST
# catalog controls the table `location` and can answer with its own
# `s3.endpoint`, so the client would then sign SigV4 requests to a
# server-nominated host using those keys. Scoped to the connections that can
# actually need them.
#' @noRd
properties_from_env <- function(type = "rest", storage = "auto", warehouse = NULL) {
  out <- list()

  for (var in names(credential_vars)) {
    value <- Sys.getenv(var, unset = "")
    if (nzchar(value)) out[[credential_vars[[var]]]] <- value
  }

  if (uses_object_storage(type, storage, warehouse)) {
    for (var in names(aws_fallbacks)) {
      prop <- aws_fallbacks[[var]]
      if (!is.null(out[[prop]])) next
      value <- Sys.getenv(var, unset = "")
      if (nzchar(value)) out[[prop]] <- value
    }
  }

  out
}

# The host part of a URI, with any userinfo and port removed.
#' @noRd
uri_host <- function(x) {
  authority <- sub("[/?#].*$", "", sub("^[^:]*://", "", x))
  authority <- sub("^.*@", "", authority)
  sub(":[0-9]+$", "", authority)
}

# A URI that would carry a credential in the clear.
#
# No scheme at all is not this function's business -- iceberg-rust will reject
# it -- and loopback over http is the ordinary development case.
#' @noRd
sends_in_cleartext <- function(x) {
  if (is.null(x) || !nzchar(x) || !grepl("://", x, fixed = TRUE)) {
    return(FALSE)
  }
  scheme <- tolower(sub("://.*$", "", x))
  if (scheme %in% c("https", "wss")) {
    return(FALSE)
  }
  !(uri_host(x) %in% c("localhost", "127.0.0.1", "::1", "[::1]", "0.0.0.0"))
}

# Refuse to put a credential on the wire unencrypted.
#
# `properties_from_env()` has already loaded whatever the environment holds, so
# by this point a bearer token is one `block_on` away from an `Authorization`
# header. Over `http://` that header, and the OAuth2 exchange's
# `client_id:client_secret` body, are readable by anything on the path. An error
# rather than a warning, because a warning does not stop the request; the escape
# hatch is one environment variable, and loopback is exempt already.
#' @noRd
check_credential_transport <- function(props, call = rlang::caller_env()) {
  supplied <- intersect(names(props), secret_props)
  if (!length(supplied)) {
    return(invisible(NULL))
  }
  if (env_flag("ICEBERGR_ALLOW_INSECURE_CREDENTIALS")) {
    return(invisible(NULL))
  }

  endpoints <- c(uri = props[["uri"]], `oauth2-server-uri` = props[["oauth2-server-uri"]])
  bad <- endpoints[vapply(endpoints, sends_in_cleartext, logical(1))]
  if (!length(bad)) {
    return(invisible(NULL))
  }

  abort(
    c(
      paste0(
        "Refusing to send a credential to ",
        encodeString(unname(bad)[[1]]), " over an unencrypted connection."
      ),
      i = paste0(
        "These credential properties are set: ",
        paste(sort(supplied), collapse = ", "), "."
      ),
      i = "Use an https:// endpoint, or unset the credential.",
      i = paste0(
        "To proceed anyway, set ICEBERGR_ALLOW_INSECURE_CREDENTIALS=true. ",
        "A loopback address needs no exemption."
      )
    ),
    call = call
  )
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
#'     `ICEBERGR_S3_SESSION_TOKEN`}{Object storage credentials.}
#' }
#'
#' The standard `AWS_*` variables are a fallback for the `ICEBERGR_S3_*` ones,
#' but only for a connection that addresses object storage: `storage = "s3"`,
#' `type = "glue"`, or an `s3://` `warehouse`. They are *not* forwarded to a
#' catalog that has no object storage in sight, because a third-party REST
#' catalog controls each table's `location` and may answer with its own
#' `s3.endpoint` -- at which point ambient keys would sign requests to a host it
#' chose. Set `storage = "s3"` if a REST catalog identified by name needs them.
#'
#' A credential is never sent over an unencrypted connection: an `http://`
#' `uri` or OAuth2 endpoint is an error whenever any credential property is
#' populated. A loopback address is exempt, since developing against a local
#' catalog is ordinary, and `ICEBERGR_ALLOW_INSECURE_CREDENTIALS=true` overrides
#' the check.
#'
#' Catalog properties are never printed, logged or included in error messages,
#' and `user:password@` in a `uri` is redacted when a catalog is printed. A
#' credential property passed through `...` anyway is accepted but warned about,
#' since a script is the one place it should not be.
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

  props <- properties_from_env(type, storage, warehouse)
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

  # After `...`, so that a credential passed there is covered too.
  check_credential_transport(props)

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

# `user:password@host` in a URI is a credential, and `uri` is a property like
# any other -- so printing it verbatim contradicted the line below and put the
# password one `saveRDS()` or knitr cache away.
#' @noRd
redact_userinfo <- function(x) {
  sub("^([A-Za-z][A-Za-z0-9+.-]*://)[^/@]*@", "\\1<redacted>@", x)
}

#' @export
print.icebergr_catalog <- function(x, ...) {
  cat("<icebergr_catalog>\n")
  cat("  type:      ", x$type, "\n", sep = "")
  cat("  name:      ", x$name, "\n", sep = "")
  if (!is.null(x$uri)) cat("  uri:       ", redact_userinfo(x$uri), "\n", sep = "")
  if (!is.null(x$warehouse)) cat("  warehouse: ", x$warehouse, "\n", sep = "")
  # Properties are deliberately not shown: they routinely hold credentials.
  invisible(x)
}
