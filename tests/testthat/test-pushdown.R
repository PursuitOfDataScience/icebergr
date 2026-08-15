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

test_that("%in% keeps the class of a Date or timestamp set", {
  catalog <- local_namespace()
  events <- data.frame(
    id = 1:4L,
    day = as.Date(c("2024-01-01", "2024-02-01", "2024-03-01", "2024-04-01")),
    ts = as.POSIXct(
      c(
        "2024-01-01 00:00:00", "2024-02-01 00:00:00",
        "2024-03-01 00:00:00", "2024-04-01 00:00:00"
      ),
      tz = "UTC"
    )
  )
  tbl <- seed_table(catalog, "db.events", events)

  # The set goes through as.list(), which each element's own class has to survive.
  # Stripped to bare numbers, a Date would still land correctly by coincidence --
  # its numeric value is days since the epoch, which is Iceberg's own
  # representation -- but a POSIXct is *seconds* where Iceberg wants
  # microseconds, so the comparison would be wrong by a factor of a million and
  # would quietly match nothing.
  days <- icebergr_collect(
    icebergr_scan(tbl, filter = day %in% as.Date(c("2024-02-01", "2024-04-01")))
  )
  expect_setequal(days$id, c(2L, 4L))

  stamps <- icebergr_collect(
    icebergr_scan(tbl, filter = ts %in% events$ts[c(1L, 3L)])
  )
  expect_setequal(stamps$id, c(1L, 3L))
})

test_that("a decimal filter returns the rows it should", {
  catalog <- local_namespace()
  schema <- nanoarrow::na_struct(list(
    id = nanoarrow::na_int32(),
    price = nanoarrow::na_decimal128(precision = 10, scale = 2)
  ))
  tbl <- icebergr_create_table(catalog, "db.prices", schema)
  tbl <- icebergr_append(
    tbl,
    data.frame(id = 1:4L, price = c(1.50, 2.25, 10.00, 99.99))
  )

  # Every one of these returned zero rows. iceberg-rust 0.10.0's row-selection
  # filter discards every row of an ordering comparison against a decimal
  # column, so the scan now runs with that stage off when a decimal is involved.
  # Equality was unaffected, which is what made it easy to miss.
  expect_setequal(icebergr_collect(icebergr_scan(tbl, filter = price > 2.25))$id, c(3L, 4L))
  expect_setequal(icebergr_collect(icebergr_scan(tbl, filter = price <= 10))$id, 1:3L)
  expect_setequal(icebergr_collect(icebergr_scan(tbl, filter = price < 2.25))$id, 1L)
  expect_setequal(icebergr_collect(icebergr_scan(tbl, filter = price >= 10))$id, c(3L, 4L))
  expect_setequal(icebergr_collect(icebergr_scan(tbl, filter = price == 1.50))$id, 1L)
  expect_setequal(icebergr_collect(icebergr_scan(tbl, filter = price != 1.50))$id, 2:4L)
  expect_setequal(
    icebergr_collect(icebergr_scan(tbl, filter = price %in% c(1.50, 99.99)))$id,
    c(1L, 4L)
  )
  # A decimal on one side of a compound filter is enough to disable the stage,
  # and the other half of the filter must still be applied.
  expect_setequal(
    icebergr_collect(icebergr_scan(tbl, filter = price > 2.25 & id < 4L))$id,
    3L
  )
  # Passing the value as a string is exact, where a double is at the mercy of
  # binary floating point.
  expect_setequal(icebergr_collect(icebergr_scan(tbl, filter = price > "2.25"))$id, c(3L, 4L))

  # More decimal places than the column's scale cannot be compared without
  # rounding, so it is refused rather than silently truncated.
  expect_error(
    icebergr_collect(icebergr_scan(tbl, filter = price > 2.255)),
    "decimal places"
  )
})

test_that("%in% with an empty set matches nothing rather than everything", {
  tbl <- split_table()
  # iceberg-rust reads an empty IN list as a predicate it cannot use, so this has
  # to become AlwaysFalse rather than falling back to a scan of the table.
  expect_equal(nrow(icebergr_collect(icebergr_scan(tbl, filter = id %in% integer()))), 0L)
  expect_equal(nrow(icebergr_scan_plan(icebergr_scan(tbl, filter = id %in% integer()))), 0L)
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

test_that("startsWith on a non-string column is refused, not turned into nonsense", {
  catalog <- local_namespace()
  events <- data.frame(
    id = 1:4L,
    amount = c(1.5, 2.5, 3.5, 4.5),
    label = c("apple", "banana", "apricot", "cherry"),
    stringsAsFactors = FALSE
  )
  tbl <- seed_table(catalog, "db.events", events)

  # This parses on both sides: R sees a column and a single string, and "1"
  # converts to the integer 1, so the scan was planned against the meaningless
  # predicate `id STARTS WITH 1`. iceberg-rust does reject that, but only from
  # inside the statistics evaluators and only for files that carry bounds.
  expect_error(
    icebergr_collect(icebergr_scan(tbl, filter = startsWith(id, "1"))),
    "startsWith"
  )
  expect_error(
    icebergr_collect(icebergr_scan(tbl, filter = startsWith(id, "1"))),
    "only on string columns"
  )
  expect_error(
    icebergr_scan_plan(icebergr_scan(tbl, filter = startsWith(amount, "1"))),
    "only on string columns"
  )
  # The negated form goes through the same check.
  expect_error(
    icebergr_scan_plan(icebergr_scan(tbl, filter = !startsWith(id, "1"))),
    "only on string columns"
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
