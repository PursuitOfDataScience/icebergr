# Schema fidelity across the Arrow round trip.
#
# These tests document what R types survive unchanged and what changes shape on
# the way through Iceberg. Where a type cannot survive -- a factor, because
# Iceberg has no dictionary type -- the test asserts the documented substitute
# rather than pretending otherwise.

test_that("integer, double and character survive unchanged", {
  catalog <- local_namespace()
  events <- data.frame(
    i = c(1L, 2L, .Machine$integer.max),
    d = c(1.5, -2.25, .Machine$double.xmax),
    s = c("a", "", "unicode: é中"),
    stringsAsFactors = FALSE
  )
  tbl <- seed_table(catalog, "db.types", events)
  got <- icebergr_collect(tbl)
  got <- got[order(got$i), ]

  expect_type(got$i, "integer")
  expect_type(got$d, "double")
  expect_type(got$s, "character")
  expect_equal(sort(got$d), sort(events$d))
  expect_setequal(got$s, events$s)
})

test_that("logical survives as logical", {
  catalog <- local_namespace()
  events <- data.frame(id = 1:3L, flag = c(TRUE, FALSE, NA))
  tbl <- seed_table(catalog, "db.types", events)
  got <- icebergr_collect(tbl)
  got <- got[order(got$id), ]

  expect_type(got$flag, "logical")
  expect_equal(got$flag, c(TRUE, FALSE, NA))
})

test_that("Date survives as Date", {
  catalog <- local_namespace()
  events <- data.frame(
    id = 1:3L,
    day = as.Date(c("1970-01-01", "2024-02-29", "2100-12-31"))
  )
  tbl <- seed_table(catalog, "db.types", events)
  got <- icebergr_collect(tbl)
  got <- got[order(got$id), ]

  expect_s3_class(got$day, "Date")
  expect_equal(got$day, events$day)
})

test_that("a timestamp with a timezone keeps its instant", {
  catalog <- local_namespace()
  events <- data.frame(
    id = 1:3L,
    ts = as.POSIXct(
      c("2024-01-01 00:00:00", "2024-06-15 12:34:56", "2024-12-31 23:59:59"),
      tz = "UTC"
    )
  )
  tbl <- seed_table(catalog, "db.types", events)
  got <- icebergr_collect(tbl)
  got <- got[order(got$id), ]

  expect_s3_class(got$ts, "POSIXct")
  # The instant must be preserved even if the zone attribute is normalised.
  expect_equal(as.numeric(got$ts), as.numeric(events$ts))
})

test_that("a timestamp column comes back labelled UTC, not +00:00", {
  # iceberg-rust names the zone "+00:00". R does not treat that as the same
  # string as "UTC", so comparing against an ordinary UTC POSIXct warns
  # "'tzone' attributes are inconsistent", and "+00:00" is not a name the
  # platform zone database knows.
  catalog <- local_namespace()
  cutoff <- as.POSIXct("2024-06-15 12:00:00", tz = "UTC")
  events <- data.frame(id = 1:2L, ts = cutoff + c(-3600, 3600))

  tbl <- seed_table(catalog, "db.types", events)
  got <- icebergr_collect(tbl)

  expect_equal(attr(got$ts, "tzone"), "UTC")
  expect_no_warning(got$ts >= cutoff)
  expect_equal(sum(got$ts >= cutoff), 1L)
})

test_that("a POSIXct with no zone is normalised rather than left to the session", {
  # nanoarrow resolves a zone-less POSIXct against the *session's* timezone, so
  # an untouched naive column would arrive as Timestamp(us, "America/Chicago")
  # -- which iceberg-rust refuses outright, and which would make the Iceberg
  # type depend on where the machine happens to be. normalise_timestamps()
  # relabels it UTC first; the instant is unchanged, only the display zone.
  withr::local_timezone("America/Chicago")

  catalog <- local_namespace()
  naive <- as.POSIXct("2024-06-15 08:00:00")
  events <- data.frame(id = 1L, ts = naive)

  tbl <- seed_table(catalog, "db.types", events)
  expect_equal(icebergr_schema(tbl)$type[[2L]], "timestamptz")

  got <- icebergr_collect(tbl)
  expect_s3_class(got$ts, "POSIXct")
  expect_equal(as.numeric(got$ts), as.numeric(naive))
})

test_that("a POSIXct appends into a zone-less timestamp column", {
  # A `timestamp` column is what Spark and PyIceberg write for a naive
  # datetime, so an R POSIXct has to be castable onto one.
  catalog <- local_namespace()
  schema <- nanoarrow::na_struct(list(
    id = nanoarrow::na_int32(),
    ts = nanoarrow::na_timestamp(timezone = "")
  ))
  tbl <- icebergr_create_table(catalog, "db.naive", schema)
  expect_equal(icebergr_schema(tbl)$type[[2L]], "timestamp")

  instant <- as.POSIXct("2024-06-15 08:00:00", tz = "UTC")
  tbl <- icebergr_append(tbl, data.frame(id = 1L, ts = instant))

  got <- icebergr_collect(tbl)
  expect_equal(nrow(got), 1L)
  expect_equal(as.numeric(got$ts), as.numeric(instant))
})

test_that("a timestamp in a non-UTC zone keeps its instant, not its clock face", {
  catalog <- local_namespace()
  events <- data.frame(
    id = 1L,
    ts = as.POSIXct("2024-06-15 08:00:00", tz = "America/New_York")
  )
  tbl <- seed_table(catalog, "db.types", events)
  got <- icebergr_collect(tbl)

  expect_equal(as.numeric(got$ts), as.numeric(events$ts))
})

test_that("integer64 survives without losing precision", {
  skip_if_not_installed("bit64")
  catalog <- local_namespace()

  # Beyond 2^53, which is exactly where a double would start lying.
  big <- bit64::as.integer64(c("9007199254740993", "-9007199254740993"))
  events <- data.frame(id = 1:2L, big = big)

  tbl <- seed_table(catalog, "db.types", events)
  got <- icebergr_collect(tbl)
  got <- got[order(got$id), ]

  expect_equal(as.character(got$big), as.character(big))
})

test_that("a factor becomes character, as documented", {
  catalog <- local_namespace()
  events <- data.frame(
    id = 1:3L,
    label = factor(c("b", "a", "b"), levels = c("a", "b", "c"))
  )
  tbl <- seed_table(catalog, "db.types", events)
  got <- icebergr_collect(tbl)
  got <- got[order(got$id), ]

  # Iceberg has no dictionary type, so the levels cannot be carried through.
  # Values are preserved; the factor-ness is not.
  expect_type(got$label, "character")
  expect_equal(got$label, c("b", "a", "b"))
})

test_that("NA survives in every nullable column type", {
  catalog <- local_namespace()
  events <- data.frame(
    id = 1:2L,
    i = c(1L, NA_integer_),
    d = c(1.5, NA_real_),
    s = c("a", NA_character_),
    b = c(TRUE, NA),
    day = as.Date(c("2024-01-01", NA)),
    stringsAsFactors = FALSE
  )
  tbl <- seed_table(catalog, "db.types", events)
  got <- icebergr_collect(tbl)
  got <- got[order(got$id), ]

  expect_true(is.na(got$i[[2L]]))
  expect_true(is.na(got$d[[2L]]))
  expect_true(is.na(got$s[[2L]]))
  expect_true(is.na(got$b[[2L]]))
  expect_true(is.na(got$day[[2L]]))
})

test_that("special double values survive", {
  catalog <- local_namespace()
  events <- data.frame(id = 1:4L, d = c(Inf, -Inf, NaN, 0))
  tbl <- seed_table(catalog, "db.types", events)
  got <- icebergr_collect(tbl)
  got <- got[order(got$id), ]

  expect_true(is.infinite(got$d[[1L]]) && got$d[[1L]] > 0)
  expect_true(is.infinite(got$d[[2L]]) && got$d[[2L]] < 0)
  expect_equal(got$d[[4L]], 0)

  # NaN is the exception, and it cannot be fixed at this layer. R conflates the
  # two missing values -- is.na(NaN) is TRUE -- so nanoarrow marks NaN as null
  # when it builds the Arrow array, and a null reads back as NA. Preserving it
  # would mean writing the validity buffer by hand instead of letting nanoarrow
  # infer it from the R vector. Asserted rather than skipped so the day the
  # behaviour changes, this test says so; the README documents it too.
  expect_true(is.na(got$d[[3L]]))
  expect_false(is.nan(got$d[[3L]]))
})

test_that("the reported schema matches the columns that come back", {
  catalog <- local_namespace()
  events <- data.frame(
    id = 1:2L,
    amount = c(1.5, 2.5),
    label = c("a", "b"),
    day = as.Date(c("2024-01-01", "2024-01-02")),
    stringsAsFactors = FALSE
  )
  tbl <- seed_table(catalog, "db.types", events)

  schema <- icebergr_schema(tbl)
  expect_equal(schema$name, names(events))
  expect_setequal(names(icebergr_collect(tbl)), schema$name)

  # Field ids are assigned and distinct.
  expect_equal(length(unique(schema$field_id)), nrow(schema))
})

test_that("column names needing quoting are handled", {
  catalog <- local_namespace()
  events <- data.frame(
    `odd name` = 1:2L,
    `with.dot` = c("a", "b"),
    check.names = FALSE,
    stringsAsFactors = FALSE
  )
  tbl <- seed_table(catalog, "db.odd", events)
  got <- icebergr_collect(tbl)

  expect_setequal(names(got), c("odd name", "with.dot"))
})
