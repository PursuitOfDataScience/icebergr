# Time travel: an earlier snapshot must not see later writes.

test_that("reading snapshot 1 does not see the second batch", {
  catalog <- local_namespace()
  first <- data.frame(id = 1:3L, amount = c(1, 2, 3))
  second <- data.frame(id = 4:6L, amount = c(4, 5, 6))

  tbl <- seed_table(catalog, "db.events", first)
  tbl <- icebergr_append(tbl, second)

  history <- icebergr_snapshots(tbl)
  expect_equal(nrow(history), 2L)

  old <- icebergr_collect(icebergr_scan(tbl, snapshot_id = history$snapshot_id[[1L]]))
  expect_equal(nrow(old), 3L)
  expect_setequal(old$id, 1:3L)
  # The whole point: the later batch must be invisible from the earlier snapshot.
  expect_false(any(4:6L %in% old$id))

  current <- icebergr_collect(tbl)
  expect_equal(nrow(current), 6L)
})

test_that("snapshot history is ordered oldest first and linked by parent", {
  catalog <- local_namespace()
  events <- data.frame(id = 1L, amount = 1)
  tbl <- seed_table(catalog, "db.events", events)
  tbl <- icebergr_append(tbl, events)
  tbl <- icebergr_append(tbl, events)

  history <- icebergr_snapshots(tbl)
  expect_equal(nrow(history), 3L)
  expect_true(all(diff(as.numeric(history$timestamp)) >= 0))

  # The first snapshot has no parent; each later one points at its predecessor.
  expect_true(is.na(history$parent_snapshot_id[[1L]]))
  expect_equal(history$parent_snapshot_id[[2L]], history$snapshot_id[[1L]])
  expect_equal(history$parent_snapshot_id[[3L]], history$snapshot_id[[2L]])
})

test_that("snapshot ids are character, to survive R's 53-bit numerics", {
  catalog <- local_namespace()
  tbl <- seed_table(catalog, "db.events", data.frame(id = 1L))
  history <- icebergr_snapshots(tbl)

  expect_type(history$snapshot_id, "character")
  expect_type(history$parent_snapshot_id, "character")
  # A real Iceberg id needs more precision than a double provides.
  expect_match(history$snapshot_id[[1L]], "^-?[0-9]+$")
})

test_that("as_of picks the snapshot current at that moment", {
  catalog <- local_namespace()
  first <- data.frame(id = 1:3L, amount = c(1, 2, 3))
  second <- data.frame(id = 4:6L, amount = c(4, 5, 6))

  tbl <- seed_table(catalog, "db.events", first)
  history_1 <- icebergr_snapshots(tbl)
  # Iceberg timestamps have millisecond resolution, so make sure the two
  # snapshots cannot land in the same millisecond.
  Sys.sleep(0.05)
  tbl <- icebergr_append(tbl, second)

  # A moment strictly between the two commits sees only the first.
  between <- icebergr_snapshots(tbl)$timestamp[[2L]] - 0.001
  got <- icebergr_collect(icebergr_scan(tbl, as_of = between))
  expect_equal(nrow(got), 3L)

  # "now" sees everything.
  got_now <- icebergr_collect(icebergr_scan(tbl, as_of = Sys.time()))
  expect_equal(nrow(got_now), 6L)

  expect_equal(nrow(history_1), 1L)
})

test_that("as_of before the first snapshot is an informative error", {
  catalog <- local_namespace()
  tbl <- seed_table(catalog, "db.events", data.frame(id = 1L))

  expect_error(
    icebergr_scan(tbl, as_of = as.POSIXct("1999-01-01", tz = "UTC")),
    "no snapshot at or before"
  )
})

test_that("snapshot_id and as_of cannot both be given", {
  catalog <- local_namespace()
  tbl <- seed_table(catalog, "db.events", data.frame(id = 1L))
  history <- icebergr_snapshots(tbl)

  expect_error(
    icebergr_scan(tbl, snapshot_id = history$snapshot_id[[1L]], as_of = Sys.time()),
    "cannot both be given"
  )
})

test_that("an unknown snapshot id is refused with the valid ones listed", {
  catalog <- local_namespace()
  tbl <- seed_table(catalog, "db.events", data.frame(id = 1L))

  expect_error(icebergr_scan(tbl, snapshot_id = "1234567890"), "not in this table's history")
})

test_that("a snapshot id too large for a double must be passed as a string", {
  catalog <- local_namespace()
  tbl <- seed_table(catalog, "db.events", data.frame(id = 1L))

  # Silently reading the wrong snapshot would be far worse than this error.
  expect_error(icebergr_scan(tbl, snapshot_id = 2^60), "too large")
})

test_that("filters bind against the snapshot's own schema", {
  catalog <- local_namespace()
  events <- data.frame(id = 1:6L, amount = as.double(1:6))
  tbl <- seed_table(catalog, "db.events", events)
  first_snapshot <- icebergr_snapshots(tbl)$snapshot_id[[1L]]
  tbl <- icebergr_append(tbl, data.frame(id = 7:9L, amount = c(7, 8, 9)))

  got <- icebergr_collect(
    icebergr_scan(tbl, filter = id > 3L, snapshot_id = first_snapshot)
  )
  expect_setequal(got$id, 4:6L)
})
