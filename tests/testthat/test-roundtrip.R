# Round trip: write a data frame, read it back, and assert it survived.

test_that("a data frame appended to a table reads back unchanged", {
  catalog <- local_namespace()
  events <- data.frame(
    id = 1:5L,
    amount = c(1.5, 2.5, 3.5, 4.5, 5.5),
    label = c("a", "b", "c", "d", "e"),
    stringsAsFactors = FALSE
  )

  tbl <- seed_table(catalog, "db.events", events)
  got <- icebergr_collect(tbl)

  expect_s3_class(got, "tbl_df")
  expect_equal(nrow(got), 5L)
  expect_setequal(names(got), names(events))

  # Iceberg does not promise row order, so compare as sets by sorting on the key.
  got <- got[order(got$id), names(events)]
  expect_equal(as.data.frame(got), events, ignore_attr = TRUE)
})

test_that("appending twice accumulates rather than replacing", {
  catalog <- local_namespace()
  first <- data.frame(id = 1:3L, amount = c(1, 2, 3))
  second <- data.frame(id = 4:6L, amount = c(4, 5, 6))

  tbl <- seed_table(catalog, "db.events", first)
  tbl <- icebergr_append(tbl, second)

  got <- icebergr_collect(tbl)
  expect_equal(nrow(got), 6L)
  expect_setequal(got$id, 1:6L)
})

test_that("columns are matched by name, not position", {
  catalog <- local_namespace()
  events <- data.frame(id = 1:3L, amount = c(1, 2, 3), label = c("a", "b", "c"))
  tbl <- seed_table(catalog, "db.events", events)

  # Same columns, deliberately shuffled.
  reordered <- data.frame(label = c("d", "e"), id = 4:5L, amount = c(4, 5))
  tbl <- icebergr_append(tbl, reordered)

  got <- icebergr_collect(tbl)
  got <- got[order(got$id), ]
  expect_equal(got$label, c("a", "b", "c", "d", "e"))
  expect_equal(got$id, 1:5L)
})

test_that("a column the table does not have is an error, not a silent drop", {
  catalog <- local_namespace()
  events <- data.frame(id = 1:3L, amount = c(1, 2, 3))
  tbl <- seed_table(catalog, "db.events", events)

  expect_error(
    icebergr_append(tbl, data.frame(id = 4L, amount = 4, typo = "x")),
    "typo"
  )
})

test_that("a missing required column is reported by name", {
  catalog <- local_namespace()
  events <- data.frame(id = 1:3L, amount = c(1, 2, 3))
  tbl <- seed_table(catalog, "db.events", events)

  expect_error(icebergr_append(tbl, data.frame(id = 4L)), "amount")
})

test_that("appending zero rows warns and commits nothing", {
  catalog <- local_namespace()
  events <- data.frame(id = 1:3L, amount = c(1, 2, 3))
  tbl <- seed_table(catalog, "db.events", events)
  before <- nrow(icebergr_snapshots(tbl))

  expect_warning(
    tbl <- icebergr_append(tbl, events[0L, ]),
    "no rows"
  )

  # An empty snapshot would be a lie in the table's history.
  expect_equal(nrow(icebergr_snapshots(tbl)), before)
  expect_equal(nrow(icebergr_collect(tbl)), 3L)
})

test_that("select reads only the requested columns", {
  catalog <- local_namespace()
  events <- data.frame(id = 1:3L, amount = c(1, 2, 3), label = c("a", "b", "c"))
  tbl <- seed_table(catalog, "db.events", events)

  got <- icebergr_collect(icebergr_scan(tbl, select = c("id", "label")))
  expect_equal(names(got), c("id", "label"))
  expect_equal(nrow(got), 3L)
})

test_that("limit bounds the number of rows returned", {
  catalog <- local_namespace()
  events <- data.frame(id = 1:100L, amount = as.double(1:100))
  tbl <- seed_table(catalog, "db.events", events)

  expect_equal(nrow(icebergr_collect(icebergr_scan(tbl, limit = 10))), 10L)
  expect_equal(nrow(icebergr_collect(icebergr_scan(tbl, limit = 0))), 0L)
  # A limit larger than the table is not an error.
  expect_equal(nrow(icebergr_collect(icebergr_scan(tbl, limit = 1000))), 100L)
})

test_that("as.data.frame and collect agree", {
  catalog <- local_namespace()
  events <- data.frame(id = 1:3L, amount = c(1, 2, 3))
  tbl <- seed_table(catalog, "db.events", events)

  expect_equal(
    as.data.frame(tbl)[order(as.data.frame(tbl)$id), ],
    as.data.frame(icebergr_collect(tbl))[order(icebergr_collect(tbl)$id), ],
    ignore_attr = TRUE
  )
})

test_that("an empty table reads back with the right columns and no rows", {
  catalog <- local_namespace()
  schema <- data.frame(
    id = integer(), amount = double(), label = character(),
    stringsAsFactors = FALSE
  )
  tbl <- icebergr_create_table(catalog, "db.empty", schema)

  got <- icebergr_collect(tbl)
  expect_equal(nrow(got), 0L)
  expect_setequal(names(got), c("id", "amount", "label"))
})

test_that("compression choices all round trip", {
  catalog <- local_namespace()
  events <- data.frame(id = 1:10L, amount = as.double(1:10))

  for (codec in c("zstd", "snappy", "uncompressed")) {
    name <- paste0("db.events_", codec)
    tbl <- icebergr_create_table(catalog, name, events)
    tbl <- icebergr_append(tbl, events, compression = codec)
    expect_equal(nrow(icebergr_collect(tbl)), 10L, info = codec)
  }
})

test_that("dplyr::collect() reaches the same code as icebergr_collect()", {
  # Registered in .onLoad() rather than imported: dplyr is a heavy dependency
  # for the sake of one generic, so the method only exists if dplyr does.
  skip_if_not_installed("dplyr")

  catalog <- local_namespace()
  events <- data.frame(id = 1:3L, amount = c(1, 2, 3))
  tbl <- seed_table(catalog, "db.events", events)

  expect_equal(
    dplyr::collect(tbl)[order(dplyr::collect(tbl)$id), ],
    icebergr_collect(tbl)[order(icebergr_collect(tbl)$id), ]
  )
  expect_equal(
    nrow(dplyr::collect(icebergr_scan(tbl, filter = id > 1L))),
    2L
  )
})

test_that("an unknown compression codec is rejected", {
  catalog <- local_namespace()
  events <- data.frame(id = 1L, amount = 1)
  tbl <- icebergr_create_table(catalog, "db.events", events)
  expect_error(icebergr_append(tbl, events, compression = "brotli"))
})
