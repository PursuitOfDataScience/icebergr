# Catalog behaviour, including that credentials do not leak.

test_that("a memory catalog opens over a warehouse directory", {
  warehouse <- withr::local_tempdir("warehouse")
  catalog <- icebergr_catalog("memory", warehouse = warehouse)

  expect_s3_class(catalog, "icebergr_catalog")
  expect_equal(catalog$type, "memory")
  expect_equal(icebergr_list_namespaces(catalog), character())
})

test_that("a memory catalog requires an existing warehouse", {
  expect_error(icebergr_catalog("memory"), "`warehouse` is required")
  expect_error(
    icebergr_catalog("memory", warehouse = file.path(tempdir(), "nope-does-not-exist")),
    "does not exist"
  )
})

test_that("a REST catalog requires a uri", {
  expect_error(icebergr_catalog("rest"), "`uri` is required")
})

test_that("there is no hadoop catalog, and the error says what to use", {
  # iceberg-rust does not implement one, so promising it would be a lie.
  expect_error(icebergr_catalog("hadoop"), "'arg' should be one of")
})

test_that("namespaces can be created, listed and nested", {
  catalog <- local_catalog()

  icebergr_create_namespace(catalog, "db")
  expect_equal(icebergr_list_namespaces(catalog), "db")

  icebergr_create_namespace(catalog, c("db", "sub"))
  # A nested namespace is reported dot-joined.
  expect_true("db.sub" %in% icebergr_list_namespaces(catalog, parent = "db"))
})

test_that("a dotted string and a character vector name the same namespace", {
  catalog <- local_catalog()
  icebergr_create_namespace(catalog, "a.b")
  expect_true("a.b" %in% icebergr_list_namespaces(catalog, parent = "a"))
})

test_that("a doubled separator does not create a namespace level nothing can name", {
  # "a..b" split to c("a", "", "b"), which the catalog accepted and then listed
  # back as "a." -- unreachable, since parse_identifier() reads "a..b.events" as
  # c("a", "b"). The two spellings have to agree.
  catalog <- local_catalog()
  icebergr_create_namespace(catalog, "a..b")

  expect_equal(icebergr_list_namespaces(catalog, parent = "a"), "a.b")
  expect_equal(icebergr_list_tables(catalog, "a..b"), character())

  # The table lands where the namespace is, whichever spelling names it.
  icebergr_create_table(catalog, "a..b.events", data.frame(id = integer()))
  expect_equal(icebergr_list_tables(catalog, "a.b"), "events")
})

test_that("a namespace of nothing but separators is refused", {
  catalog <- local_catalog()
  expect_error(icebergr_create_namespace(catalog, "."), "no namespace levels")
})

test_that("tables are listed within their namespace", {
  catalog <- local_namespace()
  expect_equal(icebergr_list_tables(catalog, "db"), character())

  icebergr_create_table(catalog, "db.one", data.frame(id = integer()))
  icebergr_create_table(catalog, "db.two", data.frame(id = integer()))

  expect_setequal(icebergr_list_tables(catalog, "db"), c("one", "two"))
})

test_that("opening a table that does not exist is an informative error", {
  catalog <- local_namespace()
  expect_error(icebergr_table(catalog, "db.absent"), "could not open table")
})

test_that("a table identifier must include a namespace", {
  catalog <- local_namespace()
  expect_error(icebergr_table(catalog, "events"), "namespace.table")
  expect_error(icebergr_table(catalog, ""), "non-empty")
})

test_that("printing a catalog never reveals its properties", {
  warehouse <- withr::local_tempdir("warehouse")
  withr::local_envvar(ICEBERGR_REST_TOKEN = "super-secret-token")

  catalog <- icebergr_catalog("memory", warehouse = warehouse)
  printed <- paste(capture.output(print(catalog)), collapse = "\n")

  # A token in a print method ends up in knitr output and in transcripts.
  expect_false(grepl("super-secret-token", printed, fixed = TRUE))
  expect_match(printed, "icebergr_catalog")
})

test_that("the token really does reach the property map", {
  # Without this the leak tests below would pass vacuously, which is exactly how
  # a leak test stops being one.
  withr::local_envvar(ICEBERGR_REST_TOKEN = "super-secret-token")
  props <- properties_from_env()

  expect_equal(props[["token"]], "super-secret-token")
})

test_that("catalog errors do not echo property values", {
  withr::local_envvar(ICEBERGR_REST_TOKEN = "super-secret-token")

  # A REST catalog is built lazily, so constructing one against a dead port
  # succeeds; it is the first request that fails. The error has to arrive one
  # way or the other, so drive it out rather than letting the test quietly
  # assert nothing.
  err <- tryCatch(
    {
      catalog <- icebergr_catalog("rest", uri = "http://127.0.0.1:1/does-not-exist")
      icebergr_list_namespaces(catalog)
      NULL
    },
    error = function(e) conditionMessage(e)
  )

  expect_type(err, "character")
  expect_false(grepl("super-secret-token", err, fixed = TRUE))
})

test_that("a failure to connect reports property keys, and only keys", {
  # Straight at the binding: every route to a connect-time failure through
  # icebergr_catalog() is now caught by its own argument checks first, which is
  # the right behaviour but leaves config_err() untested.
  err <- tryCatch(
    rs_catalog_connect(
      kind = "rest",
      name = "icebergr",
      storage = "auto",
      keys = c("uri", "token"),
      values = c("", "super-secret-token")
    ),
    error = function(e) conditionMessage(e)
  )

  expect_type(err, "character")
  expect_false(grepl("super-secret-token", err, fixed = TRUE))
  # Keys are safe to report and are genuinely useful for debugging.
  expect_match(err, "keys only", fixed = TRUE)
  expect_match(err, "token")
  expect_match(err, "uri")
})

test_that("a blank uri is treated as a missing one", {
  # Sys.getenv() on an unset variable returns "", which is the usual way to end
  # up here empty-handed.
  expect_error(icebergr_catalog("rest", uri = ""), "`uri` is required")
  expect_error(icebergr_catalog("rest", uri = "  "), "`uri` is required")
})

test_that("passing a credential as an argument warns about leaking it", {
  warehouse <- withr::local_tempdir("warehouse")
  expect_warning(
    icebergr_catalog("memory", warehouse = warehouse, token = "inline-secret"),
    "risks leaking"
  )
})

test_that("unnamed catalog properties are rejected", {
  warehouse <- withr::local_tempdir("warehouse")
  # `uri` has to be supplied by name here. It sits before `...` in the
  # signature, so a bare third argument matches it positionally and never
  # reaches the dots -- which is why this has to be written out rather than
  # passed as icebergr_catalog("memory", warehouse = warehouse, "positional").
  expect_error(
    icebergr_catalog("memory", uri = NULL, warehouse = warehouse, "positional"),
    "must be named"
  )
})

test_that("Glue and S3 report clearly when not compiled in", {
  support <- icebergr_spec_support()

  if (!"glue" %in% support$cargo_features) {
    expect_error(icebergr_catalog("glue"), "glue")
    # The message should say how to get it, not just that it is missing.
    expect_error(icebergr_catalog("glue"), "ICEBERGR_CARGO_FEATURES")
  } else {
    expect_true("glue" %in% support$catalogs)
  }
})

test_that("a table handle prints its identity and schema", {
  catalog <- local_namespace()
  tbl <- seed_table(catalog, "db.events", data.frame(id = 1:3L, amount = c(1, 2, 3)))

  printed <- paste(capture.output(print(tbl)), collapse = "\n")
  expect_match(printed, "db.events")
  expect_match(printed, "icebergr_table")
  expect_match(printed, "id")
})

test_that("a scan prints whether the filter was pushed down", {
  catalog <- local_namespace()
  tbl <- seed_table(catalog, "db.events", data.frame(id = 1:3L, amount = c(1, 2, 3)))

  scan <- icebergr_scan(tbl, filter = id > 1L, limit = 2)
  printed <- paste(capture.output(print(scan)), collapse = "\n")

  expect_match(printed, "pushed down")
  # limit is not pushdown, and saying so avoids a performance trap.
  expect_match(printed, "not pushed down")
})
