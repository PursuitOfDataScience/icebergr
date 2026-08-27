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

test_that("table existence is an answer, not an error to be caught", {
  catalog <- local_namespace()

  expect_false(icebergr_table_exists(catalog, "db.events"))
  icebergr_create_table(catalog, "db.events", data.frame(id = integer()))
  expect_true(icebergr_table_exists(catalog, "db.events"))

  # A namespace that does not exist is still just "no".
  expect_false(icebergr_table_exists(catalog, "nope.events"))
  expect_error(icebergr_table_exists("not a catalog", "db.x"), "icebergr_catalog")
  expect_error(icebergr_table_exists(catalog, "events"), "namespace.table")
})

test_that("reload picks up a commit another handle made", {
  catalog <- local_namespace()
  events <- data.frame(id = 1:3L)
  tbl <- icebergr_create_table(catalog, "db.events", events)

  # A second handle on the same table, as another session would hold it.
  stale <- icebergr_table(catalog, "db.events")
  tbl <- icebergr_append(tbl, events)

  # A handle is a snapshot of the metadata, so the second one cannot see the
  # commit. That is the guarantee, not a bug -- reload is how you opt out of it.
  expect_equal(nrow(icebergr_collect(stale)), 0L)
  fresh <- icebergr_reload(stale)
  expect_equal(nrow(icebergr_collect(fresh)), 3L)

  # The handle passed in is left alone, as with icebergr_append().
  expect_equal(nrow(icebergr_collect(stale)), 0L)
  expect_s3_class(fresh, "icebergr_table")
  expect_error(icebergr_reload("not a table"), "icebergr_table")
})

test_that("an unpartitioned table reports zero partition fields", {
  catalog <- local_namespace()
  tbl <- seed_table(catalog, "db.events", data.frame(id = 1:3L))

  parts <- icebergr_partitions(tbl)
  expect_s3_class(parts, "tbl_df")
  expect_equal(nrow(parts), 0L)
  expect_named(
    parts,
    c("spec_id", "field_id", "name", "transform", "source_id", "source_name")
  )
})

test_that("a partitioned table's spec is reported, source names and all", {
  warehouse <- withr::local_tempdir("partitioned")
  catalog <- icebergr_catalog("memory", warehouse = warehouse)
  icebergr_create_namespace(catalog, "db")
  icebergr_create_table(catalog, "db.events", data.frame(
    id = integer(), event = character(), day = as.Date(character())
  ))

  # icebergr cannot create one of these, so nothing exercised this function's
  # actual purpose -- including the source_id-to-name lookup and the transform
  # rendering.
  tbl <- partitioned_table(warehouse, "db.events", list(
    list(source_id = 2L, field_id = 1000L, transform = "identity", name = "event_part"),
    list(source_id = 3L, field_id = 1001L, transform = "month", name = "day_month")
  ))

  parts <- icebergr_partitions(tbl)
  expect_equal(nrow(parts), 2L)
  expect_equal(parts$spec_id, c(0L, 0L))
  expect_equal(parts$field_id, c(1000L, 1001L))
  expect_equal(parts$name, c("event_part", "day_month"))
  expect_equal(parts$transform, c("identity", "month"))
  expect_equal(parts$source_id, c(2L, 3L))
  # Resolved from the id through the schema, which is the part worth checking.
  expect_equal(parts$source_name, c("event", "day"))

  # The print method's "partitioned by" branch was equally unreachable.
  expect_output(print(tbl), "partitioned by: identity(event), month(day)", fixed = TRUE)
})

test_that("appending to a partitioned table is refused before anything is written", {
  warehouse <- withr::local_tempdir("partitioned")
  catalog <- icebergr_catalog("memory", warehouse = warehouse)
  icebergr_create_namespace(catalog, "db")
  icebergr_create_table(catalog, "db.events", data.frame(
    id = integer(), event = character(), day = as.Date(character())
  ))
  tbl <- partitioned_table(warehouse, "db.events", list(
    list(source_id = 2L, field_id = 1000L, transform = "identity", name = "event_part")
  ))

  rows <- data.frame(id = 1:2L, event = c("a", "b"), day = as.Date("2024-01-01") + 0:1)
  before <- list.files(warehouse, pattern = "\\.parquet$", recursive = TRUE)

  # It used to get as far as the commit -- "Partition value is not compatible with
  # partition type" -- with the Parquet files already in the warehouse and nothing
  # referencing them.
  expect_error(icebergr_append(tbl, rows), "partitioned by identity(event)", fixed = TRUE)
  expect_error(icebergr_append(tbl, rows), "unpartitioned tables")

  after <- list.files(warehouse, pattern = "\\.parquet$", recursive = TRUE)
  expect_equal(after, before)

  # Reading one is still fine; only writing is refused.
  expect_equal(nrow(icebergr_collect(tbl)), 0L)
})

test_that("a metadata file Iceberg cannot name a successor for is refused early", {
  warehouse <- withr::local_tempdir("badname")
  catalog <- icebergr_catalog("memory", warehouse = warehouse)
  icebergr_create_namespace(catalog, "db")
  icebergr_create_table(catalog, "db.events", data.frame(id = integer()))

  files <- list.files(warehouse,
    pattern = "metadata\\.json$",
    recursive = TRUE, full.names = TRUE
  )
  newest <- files[order(file.mtime(files))][length(files)]
  # Iceberg names these <version>-<uuid>.metadata.json and parses the current
  # name to build the next one -- during the commit, once the data files are
  # written. So this reads perfectly and used to fail its first append with
  # "Failed to convert between uuid und iceberg value ... invalid character",
  # naming neither the file nor the convention, and leaving orphan Parquet behind.
  renamed <- file.path(dirname(newest), "99999-not-a-uuid.metadata.json")
  file.copy(newest, renamed)

  reopened <- icebergr_catalog("memory", warehouse = warehouse)
  icebergr_create_namespace(reopened, "db")
  tbl <- icebergr_register_table(reopened, "db.events", renamed)

  # Reading is unaffected, which is exactly why the failure was confusing.
  expect_equal(nrow(icebergr_collect(tbl)), 0L)
  expect_equal(icebergr_schema(tbl)$name, "id")

  before <- list.files(warehouse, pattern = "\\.parquet$", recursive = TRUE)
  # Quoted in full, so the message must carry the *file name* and not the whole
  # path. Matching a bare "not-a-uuid" passed on Windows for the wrong reason: the
  # separator split missed backslashes, the entire path was tested as a file name,
  # and the substring was in there either way.
  expect_error(
    icebergr_append(tbl, data.frame(id = 1L)),
    '"99999-not-a-uuid.metadata.json"',
    fixed = TRUE
  )
  expect_error(icebergr_append(tbl, data.frame(id = 1L)), "<version>-<uuid>", fixed = TRUE)
  expect_equal(list.files(warehouse, pattern = "\\.parquet$", recursive = TRUE), before)
})

test_that("a spec v1 table reads, filters and appends", {
  warehouse <- withr::local_tempdir("v1")
  catalog <- icebergr_catalog("memory", warehouse = warehouse)
  icebergr_create_namespace(catalog, "db")
  icebergr_create_table(catalog, "db.events", data.frame(
    id = integer(), label = character()
  ))

  # The feature matrix claims v1 tables are supported, and every table these
  # tests build is v2 -- iceberg-rust defaults to it and icebergr does not expose
  # the choice. So the one v1 table here is made by hand.
  files <- list.files(warehouse,
    pattern = "metadata\\.json$",
    recursive = TRUE, full.names = TRUE
  )
  newest <- files[order(file.mtime(files))][length(files)]
  json <- sub(
    '"format-version":2', '"format-version":1',
    paste(readLines(newest, warn = FALSE), collapse = "")
  )
  path <- file.path(dirname(newest), metadata_file_name())
  writeLines(json, path)

  reopened <- icebergr_catalog("memory", warehouse = warehouse)
  icebergr_create_namespace(reopened, "db")
  tbl <- icebergr_register_table(reopened, "db.events", path)

  expect_output(print(tbl), "format:   v1", fixed = TRUE)
  expect_equal(nrow(icebergr_collect(tbl)), 0L)

  tbl <- icebergr_append(tbl, data.frame(id = 1:3L, label = c("a", "b", "c")))
  expect_equal(nrow(icebergr_collect(tbl)), 3L)
  expect_setequal(icebergr_collect(icebergr_scan(tbl, filter = id > 1L))$id, 2:3L)
  expect_equal(nrow(icebergr_snapshots(tbl)), 1L)
  # Writing to it must not quietly promote it.
  expect_output(print(tbl), "format:   v1", fixed = TRUE)
})

test_that("a table with no properties reports zero rows, with the right columns", {
  catalog <- local_namespace()
  tbl <- seed_table(catalog, "db.events", data.frame(id = 1:3L))

  props <- icebergr_properties(tbl)
  expect_s3_class(props, "tbl_df")
  expect_named(props, c("name", "value"))
  expect_type(props$name, "character")
  expect_type(props$value, "character")
  # Stated outright, because every table icebergr can create has none:
  # iceberg-rust's TableCreation carries an empty property map and icebergr does
  # not expose it. That is why the ordering claim needs the fixture below --
  # asserting sort(props$name) here compared character(0) to character(0).
  expect_equal(nrow(props), 0L)
  expect_error(icebergr_properties("not a table"), "icebergr_table")
})

test_that("a table's properties are read, and ordered by name", {
  warehouse <- withr::local_tempdir("props")
  catalog <- icebergr_catalog("memory", warehouse = warehouse)
  icebergr_create_namespace(catalog, "db")
  icebergr_create_table(catalog, "db.events", data.frame(id = integer()))

  # Deliberately not in name order on the way in, so the sort is doing work.
  tbl <- with_properties(warehouse, "db.events", c(
    "write.parquet.compression-codec" = "zstd",
    "owner" = "analytics",
    "commit.retry.num-retries" = "4"
  ))

  props <- icebergr_properties(tbl)
  expect_equal(nrow(props), 3L)
  # The documented order, asserted literally rather than against R's own
  # sort(): the Rust side sorts bytewise, while R's sort() follows the
  # collation locale, so comparing the two would be testing the locale.
  expect_equal(
    props$name,
    c("commit.retry.num-retries", "owner", "write.parquet.compression-codec")
  )
  expect_equal(props$value[[which(props$name == "owner")]], "analytics")
  expect_equal(props$value[[which(props$name == "commit.retry.num-retries")]], "4")
})

test_that("a table handle prints its identity and schema", {
  catalog <- local_namespace()
  tbl <- seed_table(catalog, "db.events", data.frame(id = 1:3L, amount = c(1, 2, 3)))

  printed <- paste(capture.output(print(tbl)), collapse = "\n")
  expect_match(printed, "db.events")
  expect_match(printed, "icebergr_table")
  expect_match(printed, "id")
})

test_that("a wide table lists ten columns and counts the rest", {
  # print() caps the listing at ten so a hundred-column table does not fill the
  # console. Nothing reached that branch: every other table in these tests has
  # five columns or fewer.
  catalog <- local_namespace()
  wide <- as.data.frame(
    stats::setNames(as.list(rep(1L, 14L)), sprintf("c%02d", 1:14))
  )
  tbl <- icebergr_create_table(catalog, "db.wide", wide)

  printed <- paste(capture.output(print(tbl)), collapse = "\n")
  expect_match(printed, "columns:  14")
  expect_match(printed, "c10 <int>", fixed = TRUE)
  expect_match(printed, "... and 4 more", fixed = TRUE)
  # The eleventh onwards are counted, not listed.
  expect_false(grepl("c11 <int>", printed, fixed = TRUE))
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
