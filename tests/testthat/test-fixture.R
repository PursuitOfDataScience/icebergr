# Tests against the offline example table from icebergr_example_table().
#
# This is a real Iceberg table on the local filesystem, read through an
# in-process memory catalog. No network and no credentials are involved.

test_that("the example table opens and reads", {
  tbl <- local_fixture_table()

  got <- icebergr_collect(tbl)
  expect_s3_class(got, "tbl_df")
  expect_equal(nrow(got), 100L)
})

test_that("the example table has the documented schema", {
  tbl <- local_fixture_table()
  schema <- icebergr_schema(tbl)

  expect_equal(schema$name, c("id", "event", "amount", "day", "recorded_at"))
})

test_that("the example table has snapshot history to travel through", {
  tbl <- local_fixture_table()
  history <- icebergr_snapshots(tbl)

  expect_gte(nrow(history), 2L)
  expect_type(history$snapshot_id, "character")

  # The earliest snapshot must hold strictly fewer rows than the latest, or
  # time-travel tests would pass for the wrong reason.
  oldest <- icebergr_collect(icebergr_scan(tbl, snapshot_id = history$snapshot_id[[1L]]))
  newest <- icebergr_collect(tbl)
  expect_lt(nrow(oldest), nrow(newest))
  expect_equal(nrow(oldest), 50L)
})

test_that("the example table spans more than one data file, so pruning is testable", {
  tbl <- local_fixture_table()
  plan <- icebergr_scan_plan(icebergr_scan(tbl))
  expect_gte(nrow(plan), 2L)
})

test_that("pushdown prunes files on the example table", {
  tbl <- local_fixture_table()

  all_files <- icebergr_scan_plan(icebergr_scan(tbl))
  filtered <- icebergr_scan_plan(icebergr_scan(tbl, filter = id > 1000L))

  expect_lt(nrow(filtered), nrow(all_files))
  expect_equal(
    nrow(icebergr_collect(icebergr_scan(tbl, filter = id > 1000L))),
    sum(icebergr_collect(tbl)$id > 1000L)
  )
})

test_that("the example table's date and timestamp columns come back as R types", {
  tbl <- local_fixture_table()
  got <- icebergr_collect(tbl)

  expect_s3_class(got$day, "Date")
  expect_s3_class(got$recorded_at, "POSIXct")
})

test_that("reading does not alter the table", {
  tbl <- local_fixture_table()
  before <- nrow(icebergr_snapshots(tbl))

  invisible(icebergr_collect(tbl))
  invisible(icebergr_collect(icebergr_scan(tbl, filter = id > 0L)))

  expect_equal(nrow(icebergr_snapshots(tbl)), before)
})

test_that("rows controls the size of each append", {
  tbl <- local_fixture_table(rows = 10L)
  expect_equal(nrow(icebergr_collect(tbl)), 20L)
})

test_that("filtering on the date and timestamp columns pushes down", {
  tbl <- local_fixture_table()

  by_date <- icebergr_collect(icebergr_scan(tbl, filter = day >= as.Date("2024-06-01")))
  expect_gt(nrow(by_date), 0L)
  expect_true(all(by_date$day >= as.Date("2024-06-01")))

  cutoff <- as.POSIXct("2024-06-01 00:00:00", tz = "UTC")
  by_time <- icebergr_collect(icebergr_scan(tbl, filter = recorded_at >= cutoff))
  expect_gt(nrow(by_time), 0L)
  expect_true(all(by_time$recorded_at >= cutoff))
})
