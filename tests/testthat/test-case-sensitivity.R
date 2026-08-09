# `case_sensitive` has to be honoured in R, not delegated.
#
# iceberg-rust looks a projected column up case-sensitively whatever a scan's
# `case_sensitive` setting says, and binds the snapshot-level predicate with
# case sensitivity hard-coded on. So a differently-cased name has to be resolved
# to the table's own spelling here, before anything reaches Rust.

mixed_case_table <- function(env = parent.frame()) {
  catalog <- local_namespace(env = env)
  seed_table(
    catalog, "db.events",
    data.frame(
      ID = 1:6L,
      Amount = as.double(1:6),
      Label = c("a", "b", "c", "d", "e", "f"),
      stringsAsFactors = FALSE
    )
  )
}

test_that("the translator matches column names exactly by default", {
  columns <- c("id", "amount")
  expect_error(
    translate_filter(quote(ID == 1L), columns, parent.frame()),
    class = "icebergr_unsupported_filter"
  )
})

test_that("the translator resolves a differently-cased name when asked", {
  columns <- c("id", "amount")

  # Resolved to the table's spelling, not the caller's: that is what
  # iceberg-rust will bind against.
  expect_equal(
    translate_filter(quote(ID == 1L), columns, parent.frame(), case_sensitive = FALSE),
    list(op = "eq", col = "id", value = 1L)
  )
  expect_equal(
    translate_filter(quote(is.na(AMOUNT)), columns, parent.frame(), case_sensitive = FALSE),
    list(op = "is_null", col = "amount")
  )
  expect_equal(
    translate_filter(quote(!is.na(AMOUNT)), columns, parent.frame(), case_sensitive = FALSE),
    list(op = "is_not_null", col = "amount")
  )
  expect_equal(
    translate_filter(quote(Id %in% c(1L, 2L)), columns, parent.frame(), case_sensitive = FALSE),
    list(op = "in", col = "id", values = list(1L, 2L))
  )
  expect_equal(
    translate_filter(quote(2L < Id), columns, parent.frame(), case_sensitive = FALSE),
    list(op = "gt", col = "id", value = 2L)
  )
})

test_that("a case-insensitive select reads the right column", {
  tbl <- mixed_case_table()

  got <- icebergr_collect(
    icebergr_scan(tbl, select = c("id", "label"), case_sensitive = FALSE)
  )
  # Named as the table names them, not as the caller asked.
  expect_equal(names(got), c("ID", "Label"))
  expect_equal(nrow(got), 6L)
})

test_that("a case-insensitive filter pushes down", {
  tbl <- mixed_case_table()

  got <- icebergr_collect(
    icebergr_scan(tbl, filter = id > 3L, case_sensitive = FALSE)
  )
  expect_setequal(got$ID, 4:6L)

  plan <- icebergr_scan_plan(
    icebergr_scan(tbl, filter = id > 100L, case_sensitive = FALSE)
  )
  expect_equal(nrow(plan), 0L)
})

test_that("the wrong case is still refused when case_sensitive is TRUE", {
  tbl <- mixed_case_table()

  expect_error(icebergr_scan(tbl, select = "id"), "Available columns")
  expect_error(
    icebergr_scan(tbl, filter = id > 3L),
    class = "icebergr_unsupported_filter"
  )
})

test_that("an empty case-insensitive scan still reports the selected columns", {
  # Exercises the Rust fallback schema, which is only reached when a scan
  # produces no batches at all and so has no batch to take a schema from.
  tbl <- mixed_case_table()

  got <- icebergr_collect(
    icebergr_scan(tbl, filter = id > 1000L, select = c("id", "amount"), case_sensitive = FALSE)
  )
  expect_equal(nrow(got), 0L)
  expect_equal(names(got), c("ID", "Amount"))
})

test_that("an empty case-sensitive scan reports the selected columns too", {
  catalog <- local_namespace()
  tbl <- seed_table(
    catalog, "db.events",
    data.frame(id = 1:3L, amount = c(1, 2, 3), label = c("a", "b", "c"))
  )

  got <- icebergr_collect(
    icebergr_scan(tbl, filter = id > 1000L, select = c("label", "id"))
  )
  expect_equal(nrow(got), 0L)
  expect_equal(names(got), c("label", "id"))
})
