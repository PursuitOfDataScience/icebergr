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

test_that("a limit past the integer range still works rather than failing on NA", {
  catalog <- local_namespace()
  tbl <- seed_table(catalog, "db.events", data.frame(id = 1:3L))

  # as.integer() turned this into NA, and the limit test then failed with
  # "missing value where TRUE/FALSE needed" instead of reading the table.
  expect_equal(nrow(icebergr_collect(icebergr_scan(tbl, limit = 3e9))), 3L)
  expect_silent(icebergr_collect(icebergr_scan(tbl, limit = 2^40)))
})

test_that("batch_size is bounded to what a C int can carry", {
  catalog <- local_namespace()
  tbl <- seed_table(catalog, "db.events", data.frame(id = 1:3L))

  # Unbounded, this reached Rust as NA and failed there with "Must not be NA".
  expect_error(icebergr_scan(tbl, batch_size = 3e9), "at most")
  expect_equal(nrow(icebergr_collect(icebergr_scan(tbl, batch_size = 2L))), 3L)
})

test_that("an empty or repeated select is refused rather than silently reinterpreted", {
  catalog <- local_namespace()
  tbl <- seed_table(catalog, "db.events", data.frame(id = 1:3L, amount = c(1, 2, 3)))

  # iceberg-rust reads an empty projection as "no projection", i.e. every
  # column -- the opposite of what asking for no columns says.
  expect_error(icebergr_scan(tbl, select = character()), "no columns would be read")
  expect_error(icebergr_scan(tbl, select = c("id", "id")), "more than once")
  # Caught after case resolution too, where the caller's spellings differ.
  expect_error(
    icebergr_scan(tbl, select = c("id", "ID"), case_sensitive = FALSE),
    "more than once"
  )
})

test_that("an NA snapshot property name is refused in R, not in Rust", {
  catalog <- local_namespace()
  events <- data.frame(id = 1:3L)
  tbl <- seed_table(catalog, "db.events", events)

  # nzchar(NA) is TRUE, so an NA name passed the emptiness check and failed
  # inside Rust with a bare "Must not be NA".
  named_na <- stats::setNames("value", NA_character_)
  expect_error(icebergr_append(tbl, events, properties = named_na), "named")
})

test_that("a handle that lost its Rust object says so instead of leaking extendr", {
  catalog <- local_namespace()
  tbl <- seed_table(catalog, "db.events", data.frame(id = 1:3L))

  # saveRDS() writes the external pointer's box, never the Rust value behind it,
  # so a restored handle points at nothing. The bare extendr message
  # ("expected non-null pointer in externalptr") reads like a package bug.
  path <- withr::local_tempfile(fileext = ".rds")
  saveRDS(list(catalog = catalog, tbl = tbl), path)
  restored <- readRDS(path)

  expect_error(icebergr_schema(restored$tbl), class = "icebergr_dead_handle")
  expect_error(icebergr_schema(restored$tbl), "no longer usable")
  expect_error(
    icebergr_list_namespaces(restored$catalog),
    class = "icebergr_dead_handle"
  )
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

test_that("a failure names the table the way the caller spelled it", {
  catalog <- local_namespace()

  # "could not create table \"events\"" named neither the string passed in nor
  # the thing that was actually missing, which was the namespace.
  expect_error(
    icebergr_create_table(catalog, "nope.events", data.frame(id = 1L)),
    "nope.events",
    fixed = TRUE
  )
  expect_error(
    icebergr_create_table(catalog, "nope.events", data.frame(id = 1L)),
    "No such namespace"
  )

  icebergr_create_table(catalog, "db.events", data.frame(id = 1L))
  expect_error(
    icebergr_create_table(catalog, "db.events", data.frame(id = 1L)),
    "db.events",
    fixed = TRUE
  )
  expect_error(icebergr_table(catalog, "db.absent"), "db.absent", fixed = TRUE)
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

test_that("an integer64 snapshot id is exact, so it is accepted rather than refused", {
  skip_if_not_installed("bit64")
  # integer64 is a double underneath, so it satisfies is.numeric() and used to be
  # measured against the same 2^53 limit as one -- and refused with "too large to
  # be represented exactly as a number", which is the one thing it is not.
  big <- bit64::as.integer64("7434046026776969423")
  expect_equal(as_snapshot_id(big), "7434046026776969423")
  expect_equal(as_snapshot_id(bit64::as.integer64(123)), "123")
})

test_that("a namespace with no levels is named as such", {
  catalog <- local_catalog()

  # character(0) means the same as NULL: no levels were given. It used to reach
  # seq_len(-1L) and report "argument must be coercible to non-negative
  # integer", which names neither the argument nor the mistake.
  expect_error(icebergr_create_namespace(catalog, character()), "`namespace` is required")
  expect_error(icebergr_list_tables(catalog, character()), "`namespace` is required")
  expect_error(icebergr_create_namespace(catalog, "."), "no namespace levels")
  # A NULL parent still means "all of them" for a listing.
  expect_equal(icebergr_list_namespaces(catalog, character()), character())
})

test_that("the example table's own arguments are validated", {
  # dir.exists() on a number reports "invalid filename argument", which reads
  # like an internal failure rather than a mistyped argument.
  expect_error(icebergr_example_table(warehouse = 42), "single string")
  expect_error(icebergr_example_table(rows = 0), "at least 1")
  # as.integer() turned this into NA, giving "NAs introduced by coercion"
  # followed by a seq_len() error, neither of which names `rows`.
  expect_error(icebergr_example_table(rows = 3e9), "at most")
})

test_that("identifiers are parsed and rejected predictably", {
  expect_equal(parse_identifier("db.events"), list(namespace = "db", name = "events"))
  expect_equal(parse_identifier("a.b.events"), list(namespace = c("a", "b"), name = "events"))
  expect_error(parse_identifier("events"), "namespace.table")
  expect_error(parse_identifier(c("a", "b")), "single non-empty string")
  expect_error(parse_identifier(NA_character_), "single non-empty string")
})
