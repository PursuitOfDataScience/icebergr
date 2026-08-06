# Argument validation, and graceful failure when Rust artefacts are missing.

test_that("functions reject objects of the wrong class", {
  expect_error(icebergr_list_namespaces("not a catalog"), "icebergr_catalog")
  expect_error(icebergr_table("not a catalog", "db.x"), "icebergr_catalog")
  expect_error(icebergr_schema("not a table"), "icebergr_table")
  expect_error(icebergr_partitions("not a table"), "icebergr_table")
  expect_error(icebergr_snapshots("not a table"), "icebergr_table")
  expect_error(icebergr_scan("not a table"), "icebergr_table")
  expect_error(icebergr_scan_plan("not a scan"), "icebergr_scan")
})

test_that("scan arguments are validated", {
  catalog <- local_namespace()
  tbl <- seed_table(catalog, "db.events", data.frame(id = 1:3L))

  expect_error(icebergr_scan(tbl, limit = -1), "non-negative")
  expect_error(icebergr_scan(tbl, limit = 1.5), "whole number")
  expect_error(icebergr_scan(tbl, batch_size = -5), "non-negative")
  expect_error(icebergr_scan(tbl, case_sensitive = NA), "TRUE or FALSE")
  expect_error(icebergr_scan(tbl, select = c("id", NA)), "character vector")
})

test_that("append properties must be a named character vector", {
  catalog <- local_namespace()
  events <- data.frame(id = 1:3L)
  tbl <- seed_table(catalog, "db.events", events)

  expect_error(icebergr_append(tbl, events, properties = "unnamed"), "named")
  expect_error(icebergr_append(tbl, events, properties = c(a = NA)), "named")
})

test_that("create_table requires a data frame or a schema", {
  catalog <- local_namespace()
  expect_error(icebergr_create_table(catalog, "db.x", 42), "data frame")
})

test_that("register_table requires the metadata file to exist", {
  catalog <- local_namespace()
  expect_error(
    icebergr_register_table(catalog, "db.x", file.path(tempdir(), "no-such-metadata.json")),
    "No metadata file"
  )
})

test_that("the missing-Rust error is informative", {
  # Simulate a half-finished source install: the R code is present but the
  # compiled routines are not reachable.
  local_mocked_bindings(
    rs_build_info = function() stop("could not find function \"wrap__rs_build_info\"")
  )
  the$rust_ok <- NULL
  withr::defer(the$rust_ok <- NULL)

  expect_error(ensure_rust(), class = "icebergr_rust_unavailable")
  err <- tryCatch(ensure_rust(), error = function(e) conditionMessage(e))
  expect_match(err, "not available")
  # It should point at the fix, not just report the symptom.
  expect_match(err, "rust-lang.org")
})

test_that("snapshot ids are validated before reaching Rust", {
  expect_error(as_snapshot_id(list(1)), "string or a number")
  expect_error(as_snapshot_id(1.5), "whole number")
  expect_error(as_snapshot_id(2^60), "too large")
  expect_equal(as_snapshot_id("123"), "123")
  expect_equal(as_snapshot_id(123), "123")
  expect_null(as_snapshot_id(NULL))
})

test_that("identifiers are parsed and rejected predictably", {
  expect_equal(parse_identifier("db.events"), list(namespace = "db", name = "events"))
  expect_equal(parse_identifier("a.b.events"), list(namespace = c("a", "b"), name = "events"))
  expect_error(parse_identifier("events"), "namespace.table")
  expect_error(parse_identifier(c("a", "b")), "single non-empty string")
  expect_error(parse_identifier(NA_character_), "single non-empty string")
})
