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

test_that("catalog errors do not echo property values", {
  withr::local_envvar(ICEBERGR_REST_TOKEN = "super-secret-token")

  err <- tryCatch(
    icebergr_catalog("rest", uri = "http://127.0.0.1:1/does-not-exist"),
    error = function(e) conditionMessage(e)
  )

  # The connection is expected to fail; what matters is what the message says.
  if (is.character(err)) {
    expect_false(grepl("super-secret-token", err, fixed = TRUE))
    # Keys are safe to report and are genuinely useful for debugging.
    expect_match(err, "keys only", fixed = TRUE)
  }
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
  expect_error(
    icebergr_catalog("memory", warehouse = warehouse, "positional"),
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
