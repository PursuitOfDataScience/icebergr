# The filter translator is pure R, so it is tested directly rather than through a
# scan. That keeps the pushdown logic under test even when the compiled library
# is unavailable, and it is where the fiddly cases live.

columns <- c("id", "amount", "label", "day", "ts", "flag")

tr <- function(expr, env = parent.frame()) {
  translate_filter(substitute(expr), columns, env)
}

js <- function(expr, env = parent.frame()) {
  filter_to_json(translate_filter(substitute(expr), columns, env))
}

test_that("comparisons translate to the matching predicate", {
  expect_equal(tr(id == 1L), list(op = "eq", col = "id", value = 1L))
  expect_equal(tr(id != 1L), list(op = "ne", col = "id", value = 1L))
  expect_equal(tr(amount < 2.5), list(op = "lt", col = "amount", value = 2.5))
  expect_equal(tr(amount <= 2.5), list(op = "lte", col = "amount", value = 2.5))
  expect_equal(tr(amount > 2.5), list(op = "gt", col = "amount", value = 2.5))
  expect_equal(tr(amount >= 2.5), list(op = "gte", col = "amount", value = 2.5))
})

test_that("a reversed comparison reverses the operator", {
  # 100 < amount means amount > 100, not amount < 100.
  expect_equal(tr(100 < amount), list(op = "gt", col = "amount", value = 100))
  expect_equal(tr(100 >= amount), list(op = "lte", col = "amount", value = 100))
  expect_equal(tr(1L == id), list(op = "eq", col = "id", value = 1L))
})

test_that("boolean operators nest", {
  out <- tr(id == 1L & amount > 2)
  expect_equal(out$op, "and")
  expect_length(out$args, 2L)
  expect_equal(out$args[[1L]]$op, "eq")
  expect_equal(out$args[[2L]]$op, "gt")

  expect_equal(tr(id == 1L | id == 2L)$op, "or")
  expect_equal(tr(!(id == 1L))$op, "not")
})

test_that("parentheses do not change the meaning", {
  expect_equal(tr((id == 1L)), tr(id == 1L))
})

test_that("null and NaN tests map to unary predicates", {
  expect_equal(tr(is.na(label)), list(op = "is_null", col = "label"))
  expect_equal(tr(is.nan(amount)), list(op = "is_nan", col = "amount"))
  # !is.na() becomes is_not_null directly rather than a negated is_null.
  expect_equal(tr(!is.na(label)), list(op = "is_not_null", col = "label"))
  expect_equal(tr(!is.nan(amount)), list(op = "is_not_nan", col = "amount"))
})

test_that("%in% becomes a set predicate", {
  out <- tr(id %in% c(1L, 2L, 3L))
  expect_equal(out$op, "in")
  expect_equal(out$col, "id")
  expect_equal(out$values, list(1L, 2L, 3L))
})

test_that("startsWith becomes a prefix predicate", {
  expect_equal(
    tr(startsWith(label, "a")),
    list(op = "starts_with", col = "label", value = "a")
  )
})

test_that("a bare name that is not a column is evaluated in the caller", {
  target <- 2024L
  expect_equal(tr(id == target), list(op = "eq", col = "id", value = 2024L))
})

test_that("a filter naming no column is rejected with a useful message", {
  other <- 1L
  expect_error(tr(other == 2L), class = "icebergr_unsupported_filter")
  expect_error(tr(other == 2L), "neither side")
})

test_that("unsupported constructs are refused rather than silently dropped", {
  expect_error(tr(sqrt(amount) > 2), class = "icebergr_unsupported_filter")
  expect_error(tr(grepl("x", label)), class = "icebergr_unsupported_filter")
  # A bare boolean column is not a comparison Iceberg can express.
  expect_error(tr(flag), class = "icebergr_unsupported_filter")
})

test_that("comparing against NA is an error pointing at is.na()", {
  expect_error(js(label == NA), "is.na")
})

test_that("%in% with NA is refused", {
  expect_error(tr(id %in% c(1L, NA)), "NA")
})

test_that("comparing against a vector suggests %in%", {
  expect_error(tr(id == c(1L, 2L)), "%in%")
})

test_that("an operator called in prefix form with too few arguments is reported", {
  # `> `(id) and `&`(id > 1) are valid calls that no infix spelling can produce,
  # and each used to index past the end of the call: "subscript out of bounds",
  # which says nothing about the filter.
  expect_error(tr(`>`(id)), class = "icebergr_unsupported_filter")
  # Named by the operator, not by deparse1(): R deparses `` `>`(id) `` as ">id",
  # which reads like a typo in the message rather than one in the filter.
  expect_error(tr(`>`(id)), "`>` takes 2 argument", fixed = TRUE)
  expect_error(tr(is.na()), "`is.na` takes 1 argument", fixed = TRUE)
  expect_error(tr(`&`(id > 1L)), class = "icebergr_unsupported_filter")
  expect_error(tr(`|`(id > 1L)), class = "icebergr_unsupported_filter")
  expect_error(tr(`%in%`(id)), class = "icebergr_unsupported_filter")
})

test_that("JSON output is well formed for the common shapes", {
  expect_equal(js(id == 1L), '{"op":"eq","col":"id","value":1}')
  expect_equal(js(label == "a"), '{"op":"eq","col":"label","value":"a"}')
  expect_equal(js(flag == TRUE), '{"op":"eq","col":"flag","value":true}')
  expect_equal(js(is.na(label)), '{"op":"is_null","col":"label"}')
  expect_equal(
    js(id == 1L & label == "a"),
    paste0(
      '{"op":"and","args":[{"op":"eq","col":"id","value":1},',
      '{"op":"eq","col":"label","value":"a"}]}'
    )
  )
})

test_that("strings are escaped so a quote cannot break the JSON", {
  expect_equal(js(label == 'a"b'), '{"op":"eq","col":"label","value":"a\\"b"}')
  expect_equal(js(label == "a\\b"), '{"op":"eq","col":"label","value":"a\\\\b"}')
  expect_equal(js(label == "a\nb"), '{"op":"eq","col":"label","value":"a\\nb"}')
})

test_that("control characters are escaped rather than emitted raw", {
  # JSON forbids an unescaped C0 control character, so one in a string literal
  # would otherwise produce a document the Rust side cannot parse. Written as an
  # octal escape so this file stays ASCII.
  expect_equal(js(label == "a\001b"), '{"op":"eq","col":"label","value":"a\\u0001b"}')
  expect_equal(js(label == "a\bb"), '{"op":"eq","col":"label","value":"a\\bb"}')
  expect_equal(js(label == "a\fb"), '{"op":"eq","col":"label","value":"a\\fb"}')
})

test_that("infinite and NaN bounds are refused, not turned into invalid JSON", {
  # "Inf" and "NaN" are not JSON tokens; emitting them fails obscurely in Rust.
  expect_error(js(amount < Inf), "infinite")
  expect_error(js(amount > -Inf), "infinite")
  expect_error(js(amount == NaN), "NaN")
  expect_error(js(amount == NaN), "is.nan")
})

test_that("dates and timestamps are sent as unambiguous ISO-8601", {
  expect_equal(
    js(day == as.Date("2024-03-01")),
    '{"op":"eq","col":"day","value":"2024-03-01"}'
  )
  # Normalised to UTC and marked with Z, so the comparison zone is explicit.
  out <- js(ts > as.POSIXct("2024-03-01 12:00:00", tz = "UTC"))
  expect_match(out, '"value":"2024-03-01T12:00:00\\.0*Z"')
})

test_that("a timestamp in a non-UTC zone is converted, not relabelled", {
  ts_est <- as.POSIXct("2024-03-01 07:00:00", tz = "America/New_York")
  out <- js(ts > ts_est)
  # 07:00 EST is 12:00 UTC.
  expect_match(out, '"value":"2024-03-01T12:00:00')
})

test_that("large integers are not silently truncated", {
  skip_if_not_installed("bit64")
  # Beyond 2^53 a double has already lost precision, so it must go as a string.
  big <- bit64::as.integer64("9007199254740993")
  expect_match(js(id == big), '"value":"9007199254740993"')
})

test_that("factors compare as their labels", {
  expect_equal(
    js(label == factor("a", levels = c("a", "b"))),
    '{"op":"eq","col":"label","value":"a"}'
  )
})

test_that("literal TRUE and FALSE are accepted", {
  expect_equal(tr(TRUE), list(op = "always_true"))
  expect_equal(tr(FALSE), list(op = "always_false"))
})

test_that("the JSON string writer survives an NA rather than erroring", {
  # NA does not reach json_string() today -- json_scalar() rejects it first, and
  # op and col are never NA -- but the control-character sweep tests each
  # element with grepl(), and `if (NA)` is an error rather than FALSE. This
  # helper should not be the thing that breaks if that ever changes.
  expect_equal(json_string(NA_character_), "\"NA\"")
  expect_equal(json_string(c("a", NA)), c("\"a\"", "\"NA\""))
})
