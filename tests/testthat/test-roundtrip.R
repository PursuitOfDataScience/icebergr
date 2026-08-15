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

test_that("an Arrow stream carrying no rows warns too, not just an empty data frame", {
  # The warning used to be driven by nrow(data), which only exists for a data
  # frame, so an empty Arrow stream was a silent no-op.
  catalog <- local_namespace()
  events <- data.frame(id = 1:3L, amount = c(1, 2, 3))
  tbl <- seed_table(catalog, "db.events", events)
  before <- nrow(icebergr_snapshots(tbl))

  stream <- nanoarrow::as_nanoarrow_array_stream(events[0L, ])
  expect_warning(tbl <- icebergr_append(tbl, stream), "no rows")
  expect_equal(nrow(icebergr_snapshots(tbl)), before)
})

test_that("a value the table's column type cannot hold is refused, not written as NA", {
  # The default Arrow cast substitutes a null for a value it cannot represent, so
  # this committed NA over the caller's data without a word.
  catalog <- local_namespace()
  tbl <- icebergr_create_table(catalog, "db.events", data.frame(id = 1L))

  expect_error(icebergr_append(tbl, data.frame(id = 3e9)), "id")
  expect_error(icebergr_append(tbl, data.frame(id = "abc")), "id")
  expect_equal(nrow(icebergr_collect(tbl)), 0L)

  # A double that is exactly an integer is the ordinary R case and must still
  # work: data.frame(id = 4) is a double, not an integer.
  tbl <- icebergr_append(tbl, data.frame(id = 4))
  expect_equal(icebergr_collect(tbl)$id, 4L)
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
  events <- data.frame(
    id = 1:10L,
    amount = as.double(1:10),
    label = letters[1:10],
    stringsAsFactors = FALSE
  )

  # Every codec the argument accepts, not a subset of them: `gzip` and `lz4` were
  # documented, reachable through match.arg, and never once written or read. LZ4
  # in particular has a history of Parquet writing one variant and readers
  # expecting another, which would show up here as unreadable data.
  for (codec in c("zstd", "snappy", "gzip", "lz4", "uncompressed")) {
    name <- paste0("db.events_", codec)
    tbl <- icebergr_create_table(catalog, name, events)
    tbl <- icebergr_append(tbl, events, compression = codec)
    got <- icebergr_collect(tbl)
    expect_equal(nrow(got), 10L, info = codec)
    expect_setequal(got$label, events$label)
    expect_equal(sum(got$amount), sum(events$amount), info = codec)
  }
})

test_that("the compression argument reaches the Parquet writer", {
  # Round-tripping does not prove the codec was applied rather than ignored.
  # Distinct file sizes do. They are all within a few hundred bytes of each other
  # because Parquet's dictionary and RLE encoding shrink data this repetitive to
  # almost nothing before any codec runs -- which is why this asserts that they
  # differ, and not that any one is smaller.
  rows <- 20000L
  events <- data.frame(
    id = rep(1L, rows),
    label = rep(strrep("a", 30L), rows),
    stringsAsFactors = FALSE
  )

  sizes <- vapply(
    c("uncompressed", "snappy", "gzip", "lz4", "zstd"),
    function(codec) {
      warehouse <- withr::local_tempdir("codec")
      catalog <- icebergr_catalog("memory", warehouse = warehouse)
      icebergr_create_namespace(catalog, "db")
      tbl <- icebergr_create_table(catalog, "db.t", events)
      tbl <- icebergr_append(tbl, events, compression = codec)
      expect_equal(nrow(icebergr_collect(tbl)), rows, info = codec)
      sum(file.size(list.files(
        warehouse,
        pattern = "\\.parquet$", recursive = TRUE, full.names = TRUE
      )))
    },
    numeric(1)
  )

  expect_length(unique(sizes), length(sizes))
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
