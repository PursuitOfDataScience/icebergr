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

test_that("a column on the value side is refused, not read as a local variable", {
  # `amount` is a column, so `id > amount` compares two columns, which an
  # Iceberg predicate cannot express. The value side used to be evaluated in
  # the caller regardless: with a local `amount` in scope the filter silently
  # became `id > <that local>`, and without one it failed with "object not
  # found" beside advice saying the name was not a column.
  expect_error(tr(id > amount), "is a column of the table", class = "icebergr_unsupported_filter")
  amount <- 5
  expect_error(tr(id > amount), "is a column of the table")
  expect_error(tr(amount < id), "is a column of the table")
  expect_error(tr(id > amount + 1), "is a column of the table")
  expect_error(tr(id %in% c(amount, 1)), "is a column of the table")
  expect_error(tr(startsWith(label, label)), "is a column of the table")

  # Case-insensitive resolution counts a differently-cased name as the column.
  AMOUNT <- 5
  expect_error(
    translate_filter(quote(id > AMOUNT), columns, environment(), case_sensitive = FALSE),
    "is a column of the table"
  )
  expect_equal(tr(id > AMOUNT), list(op = "gt", col = "id", value = 5))

  # A local whose name is not a column still works, and the field of `x$field`
  # is a name rather than a reference to the column it happens to share.
  cutoff <- 5
  expect_equal(tr(id > cutoff), list(op = "gt", col = "id", value = 5))
  limits <- list(amount = 7)
  expect_equal(tr(id > limits$amount), list(op = "gt", col = "id", value = 7))
})

test_that("a timestamp goes out to the nearest microsecond, not truncated", {
  # The double nearest 2024-01-01 00:00:00.009690 UTC is 4.4e-8 s *below* it,
  # which is how nanoarrow hands that instant back from a table, and %OS6
  # truncates: the literal used to say .009689, a microsecond early, so
  # `ts == x` missed the very row `x` was read from.
  x <- .POSIXct(1704067200.009689808, tz = "UTC")
  expect_lt(as.numeric(x) - 1704067200, 0.00969)
  expect_match(js(ts == x), '"2024-01-01T00:00:00.009690Z"', fixed = TRUE)

  # Rounding carries into the seconds rather than writing .1000000.
  y <- .POSIXct(1704067259.9999998, tz = "UTC")
  expect_match(js(ts == y), '"2024-01-01T00:01:00.000000Z"', fixed = TRUE)

  # Before the epoch the fraction still counts forwards from the second.
  z <- as.POSIXct("1969-12-31 23:59:59", tz = "UTC") + 0.25
  expect_match(js(ts == z), '"1969-12-31T23:59:59.250000Z"', fixed = TRUE)
})

test_that("a POSIXlt is read in its own zone, as strptime() returns one", {
  # as.POSIXct(x, tz = "UTC") reads a POSIXlt's wall-clock fields *as* UTC, so
  # these went out as 07:00Z and 09:00Z.
  lt <- as.POSIXlt("2024-03-01 07:00:00", tz = "America/New_York")
  expect_match(js(ts > lt), '"2024-03-01T12:00:00.000000Z"', fixed = TRUE)
  parsed <- strptime("2024-06-01 09:00:00", "%Y-%m-%d %H:%M:%S", tz = "America/New_York")
  expect_match(js(ts > parsed), '"2024-06-01T13:00:00.000000Z"', fixed = TRUE)
})

test_that("%in% with NaN points at is.nan(), not at is.na()", {
  expect_error(tr(amount %in% c(1, NaN)), "is.nan")
  expect_error(tr(amount %in% c(1, NA)), "is.na")
})

test_that("a filter held in a variable is told how to pass it, not to add == TRUE", {
  # `filter` is captured unevaluated, so only the variable's name arrives. The
  # advice for a bare boolean column, to write `f == TRUE`, made no sense here.
  f <- quote(id > 1)
  expect_error(tr(f), "not a column of the table", class = "icebergr_unsupported_filter")
  expect_error(tr(f), "do.call")
  # A column still gets the column advice.
  expect_error(tr(flag), "flag == TRUE")
})
