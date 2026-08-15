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

test_that("as_of follows the snapshot log, not every snapshot in the metadata", {
  warehouse <- withr::local_tempdir("rollback")
  catalog <- icebergr_catalog("memory", warehouse = warehouse)
  icebergr_create_namespace(catalog, "db")

  tbl <- seed_table(catalog, "db.events", data.frame(id = 1:3L))
  first <- icebergr_snapshots(tbl)$snapshot_id[[1L]]
  Sys.sleep(0.05)
  tbl <- icebergr_append(tbl, data.frame(id = 4:6L))
  second <- icebergr_snapshots(tbl)$snapshot_id[[2L]]

  # Roll back to the first snapshot. The second one stays in the snapshot list
  # with its own, later, timestamp; only the log records that it was abandoned.
  rolled <- rolled_back_table(warehouse, "db.events", first)
  back <- rolled$table

  # The list still holds both, and still reports the abandoned one as the newest.
  history <- icebergr_snapshots(back)
  expect_setequal(history$snapshot_id, c(first, second))
  expect_equal(history$snapshot_id[[2L]], second)

  # Resolved against the list, "now" picked the abandoned snapshot -- the one
  # state the table demonstrably was not in. The log says the first.
  now <- icebergr_collect(icebergr_scan(back, as_of = rolled$rolled_at + 1))
  expect_setequal(now$id, 1:3L)
  expect_equal(nrow(now), 3L)

  # A moment before the rollback still sees what was current then.
  during <- icebergr_collect(icebergr_scan(back, as_of = rolled$rolled_at - 0.5))
  expect_setequal(during$id, 1:6L)

  # And the abandoned snapshot is still readable by id, which is the point of
  # keeping it in the list.
  expect_equal(nrow(icebergr_collect(icebergr_scan(back, snapshot_id = second))), 6L)
})

test_that("icebergr_schema() reports the schema as of a snapshot", {
  catalog <- local_namespace()
  events <- data.frame(id = 1:3L, amount = as.double(1:3))
  tbl <- seed_table(catalog, "db.events", events)
  first <- icebergr_snapshots(tbl)$snapshot_id[[1L]]
  tbl <- icebergr_append(tbl, events)

  # icebergr writes append-only, so this table's schema never changes and the
  # two must agree. What is under test is that the snapshot's *own* schema is
  # what gets read: this is the lookup icebergr_scan() resolves `filter` and
  # `select` through, and it used to be the current schema unconditionally.
  expect_equal(icebergr_schema(tbl, snapshot_id = first), icebergr_schema(tbl))
  expect_error(icebergr_schema(tbl, snapshot_id = "1234567890"), "not in this table")
  expect_error(icebergr_schema(tbl, snapshot_id = "not-an-id"), "not a valid snapshot id")
})

test_that("select and filter resolve against the snapshot being read", {
  catalog <- local_namespace()
  events <- data.frame(id = 1:6L, amount = as.double(1:6), label = letters[1:6])
  tbl <- seed_table(catalog, "db.events", events)
  first <- icebergr_snapshots(tbl)$snapshot_id[[1L]]
  tbl <- icebergr_append(tbl, events)

  # Both name resolutions now go through the snapshot's schema. An unknown
  # column is still refused, and a known one still reads, whichever snapshot is
  # named.
  got <- icebergr_collect(
    icebergr_scan(tbl, select = c("id", "LABEL"), snapshot_id = first, case_sensitive = FALSE)
  )
  expect_named(got, c("id", "label"))
  expect_equal(nrow(got), 6L)

  expect_error(
    icebergr_scan(tbl, select = "no_such_column", snapshot_id = first),
    "Cannot select column"
  )
  # An invalid snapshot id is reported before the columns are looked up, since
  # which columns exist is a question about the snapshot.
  expect_error(
    icebergr_scan(tbl, select = "no_such_column", snapshot_id = "1234567890"),
    "not in this table's history"
  )
})
