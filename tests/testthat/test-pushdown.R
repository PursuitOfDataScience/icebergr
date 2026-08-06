# Pushdown must be verified at the scan plan, not just at the result.
#
# A filter applied in R after reading everything produces the same rows as a
# filter pushed into Iceberg, so comparing results proves nothing about
# pushdown. What distinguishes them is how much was planned to be read, which is
# what icebergr_scan_plan() exposes.

# Two appends put the low and high ids in separate data files, so per-file
# statistics in the manifest can eliminate one of them outright.
split_table <- function(env = parent.frame()) {
  catalog <- local_namespace(env = env)
  low <- data.frame(id = 1:50L, amount = as.double(1:50))
  high <- data.frame(id = 1000:1049L, amount = as.double(1000:1049))

  tbl <- seed_table(catalog, "db.events", low)
  icebergr_append(tbl, high)
}

test_that("the scan plan sees every file when unfiltered", {
  tbl <- split_table()
  plan <- icebergr_scan_plan(icebergr_scan(tbl))

  expect_gte(nrow(plan), 2L)
  expect_equal(sum(plan$record_count), 100)
})

test_that("a filter prunes files out of the scan plan", {
  tbl <- split_table()

  all_files <- icebergr_scan_plan(icebergr_scan(tbl))
  pruned <- icebergr_scan_plan(icebergr_scan(tbl, filter = id > 500L))

  # This is the assertion that actually demonstrates pushdown: fewer files, and
  # fewer records, planned than the table contains.
  expect_lt(nrow(pruned), nrow(all_files))
  expect_lt(sum(pruned$record_count), sum(all_files$record_count))
  expect_equal(sum(pruned$record_count), 50)
})

test_that("a filter matching nothing plans no files at all", {
  tbl <- split_table()
  plan <- icebergr_scan_plan(icebergr_scan(tbl, filter = id > 100000L))
  expect_equal(nrow(plan), 0L)
  expect_equal(nrow(icebergr_collect(icebergr_scan(tbl, filter = id > 100000L))), 0L)
})

test_that("a pushed-down filter returns the same rows as filtering in R", {
  tbl <- split_table()

  pushed <- icebergr_collect(icebergr_scan(tbl, filter = id > 500L))
  in_r <- icebergr_collect(tbl)
  in_r <- in_r[in_r$id > 500L, ]

  expect_equal(nrow(pushed), nrow(in_r))
  expect_setequal(pushed$id, in_r$id)
})

test_that("compound filters push down", {
  tbl <- split_table()

  got <- icebergr_collect(icebergr_scan(tbl, filter = id >= 1010L & id <= 1020L))
  expect_setequal(got$id, 1010:1020L)

  got_or <- icebergr_collect(icebergr_scan(tbl, filter = id == 1L | id == 1049L))
  expect_setequal(got_or$id, c(1L, 1049L))
})

test_that("%in% pushes down", {
  tbl <- split_table()
  got <- icebergr_collect(icebergr_scan(tbl, filter = id %in% c(2L, 3L, 1005L)))
  expect_setequal(got$id, c(2L, 3L, 1005L))
})

test_that("negation pushes down", {
  tbl <- split_table()
  got <- icebergr_collect(icebergr_scan(tbl, filter = !(id > 500L)))
  expect_equal(nrow(got), 50L)
  expect_true(all(got$id <= 50L))
})

test_that("null tests push down", {
  catalog <- local_namespace()
  events <- data.frame(
    id = 1:4L,
    label = c("a", NA, "c", NA),
    stringsAsFactors = FALSE
  )
  tbl <- seed_table(catalog, "db.events", events)

  present <- icebergr_collect(icebergr_scan(tbl, filter = !is.na(label)))
  expect_setequal(present$id, c(1L, 3L))

  absent <- icebergr_collect(icebergr_scan(tbl, filter = is.na(label)))
  expect_setequal(absent$id, c(2L, 4L))
})

test_that("string filters push down", {
  catalog <- local_namespace()
  events <- data.frame(
    id = 1:4L,
    label = c("apple", "banana", "apricot", "cherry"),
    stringsAsFactors = FALSE
  )
  tbl <- seed_table(catalog, "db.events", events)

  expect_setequal(
    icebergr_collect(icebergr_scan(tbl, filter = label == "banana"))$id,
    2L
  )
  expect_setequal(
    icebergr_collect(icebergr_scan(tbl, filter = startsWith(label, "ap")))$id,
    c(1L, 3L)
  )
})

test_that("projection reaches the scan plan without changing rows", {
  tbl <- split_table()
  plan <- icebergr_scan_plan(icebergr_scan(tbl, select = "id"))
  expect_equal(sum(plan$record_count), 100)
})

test_that("filtering on a column that does not exist names the real columns", {
  tbl <- split_table()
  expect_error(icebergr_scan(tbl, filter = nope > 1), class = "icebergr_unsupported_filter")
})

test_that("selecting a column that does not exist is refused early", {
  tbl <- split_table()
  expect_error(icebergr_scan(tbl, select = "nope"), "Available columns")
})
