# icebergr_register_table(confine = ) -- see #2.
#
# A metadata file names absolute paths for its data, so registering one from an
# untrusted source reads whatever it nominates.

test_that("is_inside is not fooled by a shared prefix", {
  expect_true(is_inside("/w/db/t/metadata/1-x.json", "/w", windows = FALSE))
  expect_true(is_inside("/w", "/w", windows = FALSE))
  expect_true(is_inside("/w/x", "/w/", windows = FALSE))

  # The near-miss this check exists for.
  expect_false(is_inside("/warehouse-old/x", "/warehouse", windows = FALSE))
  expect_false(is_inside("/etc/passwd", "/w", windows = FALSE))

  # Windows compares case-insensitively; both branches run on either platform.
  expect_true(is_inside("C:/W/DB/t.json", "c:/w", windows = TRUE))
  expect_false(is_inside("C:/W/DB/t.json", "c:/w", windows = FALSE))
})

test_that("only a local directory can be confined against", {
  expect_true(is_local_dir("/tmp/wh"))
  expect_true(is_local_dir("C:/wh"))
  expect_false(is_local_dir("s3://bucket/wh"))
  expect_false(is_local_dir("https://host/wh"))
})

test_that("registering inside the warehouse works and outside is refused", {
  warehouse <- withr::local_tempdir("warehouse")
  catalog <- icebergr_catalog("memory", warehouse = warehouse)
  icebergr_create_namespace(catalog, "db")
  tbl <- icebergr_create_table(catalog, "db.events", data.frame(id = 1:3))
  tbl <- icebergr_append(tbl, data.frame(id = 1:3))

  files <- list.files(warehouse,
    pattern = "metadata\\.json$", recursive = TRUE,
    full.names = TRUE
  )
  newest <- files[order(file.mtime(files))][length(files)]

  reopened <- icebergr_catalog("memory", warehouse = warehouse)
  icebergr_create_namespace(reopened, "db")

  # The documented flow: the file is inside the warehouse it belongs to.
  again <- icebergr_register_table(reopened, "db.events", newest)
  expect_equal(nrow(icebergr_collect(again)), 3L)

  # The same file, from a catalog rooted somewhere else.
  elsewhere <- withr::local_tempdir("elsewhere")
  other <- icebergr_catalog("memory", warehouse = elsewhere)
  icebergr_create_namespace(other, "db")
  expect_error(
    icebergr_register_table(other, "db.events", newest),
    "outside the catalog's warehouse"
  )
  # And with the guard off, the same call is allowed.
  expect_no_error(
    icebergr_register_table(other, "db.events", newest, confine = FALSE)
  )
})

test_that("confine rejects a non-logical value", {
  warehouse <- withr::local_tempdir("warehouse")
  catalog <- icebergr_catalog("memory", warehouse = warehouse)
  expect_error(
    icebergr_register_table(catalog, "db.t", warehouse, confine = "yes"),
    "TRUE or FALSE"
  )
})

test_that("a renamed metadata file reads, and its append is refused before writing", {
  # writing.Rmd states this, and nothing pinned it end to end: the Rust unit
  # tests cover the name helper, not the register -> read -> refuse path. The
  # orphan check is the part that matters -- Iceberg itself only inspects the
  # name when the commit is attempted, by which point the Parquet is already in
  # the warehouse and this package has no maintenance operation to clear it.
  warehouse <- withr::local_tempdir("warehouse")
  catalog <- icebergr_catalog("memory", warehouse = warehouse)
  icebergr_create_namespace(catalog, "db")
  tbl <- icebergr_create_table(catalog, "db.events", data.frame(id = 1:3))
  tbl <- icebergr_append(tbl, data.frame(id = 1:3))

  files <- list.files(warehouse,
    pattern = "metadata\\.json$", recursive = TRUE,
    full.names = TRUE
  )
  newest <- files[order(file.mtime(files))][length(files)]
  renamed <- file.path(dirname(newest), "renamed.metadata.json")
  expect_true(file.copy(newest, renamed))

  reopened <- icebergr_catalog("memory", warehouse = warehouse)
  icebergr_create_namespace(reopened, "db")

  # Registering and reading are both fine; only the append cannot work.
  from_renamed <- icebergr_register_table(reopened, "db.events", renamed)
  expect_equal(nrow(icebergr_collect(from_renamed)), 3L)

  parquet <- function() {
    length(list.files(warehouse, pattern = "\\.parquet$", recursive = TRUE))
  }
  before <- parquet()
  expect_error(
    icebergr_append(from_renamed, data.frame(id = 9L)),
    "renamed\\.metadata\\.json"
  )
  expect_equal(parquet(), before)
})
