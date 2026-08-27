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

test_that("integer64 stays exact inside a struct, not only at the top level", {
  skip_if_not_installed("bit64")
  catalog <- local_namespace()
  schema <- nanoarrow::na_struct(list(
    flat = nanoarrow::na_int64(),
    nest = nanoarrow::na_struct(list(
      big = nanoarrow::na_int64(),
      lab = nanoarrow::na_string()
    ))
  ))
  tbl <- icebergr_create_table(catalog, "db.nested64", schema)

  # 2^53 + 1: the first integer a double cannot represent. The prototype that
  # asks nanoarrow for integer64 only looked at top-level children, so this came
  # back as 9007199254740992 from inside the struct while the identical top-level
  # value came back exact.
  exact <- "9007199254740993"
  events <- data.frame(flat = bit64::as.integer64(exact))
  events$nest <- data.frame(big = bit64::as.integer64(exact), lab = "x")
  tbl <- icebergr_append(tbl, events)

  got <- icebergr_collect(tbl)
  expect_equal(as.character(got$flat), exact)
  expect_equal(as.character(got$nest$big), exact)
  expect_equal(got$nest$lab, "x")

  # The limit path converts batch by batch rather than the whole stream, so it
  # needs the same prototype.
  limited <- icebergr_collect(icebergr_scan(tbl, limit = 1))
  expect_equal(as.character(limited$nest$big), exact)
})

test_that("without bit64 a long narrows to a double, as documented", {
  skip_if_not_installed("bit64")
  catalog <- local_namespace()
  exact <- "9007199254740993"
  events <- data.frame(id = 1:2L, big = bit64::as.integer64(c(exact, "1")))
  tbl <- seed_table(catalog, "db.big", events)

  # bit64 is only suggested, so the type-fidelity table promises that a `long`
  # falls back to nanoarrow's own conversion when it is absent -- lossily, which
  # is the whole reason int64_ptype() exists. Nothing covered that branch, and it
  # cannot be reached by uninstalling a package mid-suite, so the branch point
  # itself is mocked.
  local_mocked_bindings(int64_ptype = function(schema) NULL)

  got <- icebergr_collect(tbl)
  got <- got[order(got$id), ]
  expect_type(got$big, "double")
  # 2^53 + 1 is exactly the value a double cannot hold, so it comes back even.
  expect_equal(format(got$big[[1L]], scientific = FALSE), "9007199254740992")
  # The limit path converts batch by batch and must degrade the same way rather
  # than erroring on a NULL prototype.
  expect_type(icebergr_collect(icebergr_scan(tbl, limit = 1))$big, "double")
})

test_that("a struct with no int64 in it is left as nanoarrow converts it", {
  catalog <- local_namespace()
  schema <- nanoarrow::na_struct(list(
    a = nanoarrow::na_int32(),
    s = nanoarrow::na_struct(list(d = nanoarrow::na_double()))
  ))
  tbl <- icebergr_create_table(catalog, "db.plain", schema)
  events <- data.frame(a = 1L)
  events$s <- data.frame(d = 1.5)
  tbl <- icebergr_append(tbl, events)

  got <- icebergr_collect(tbl)
  expect_type(got$a, "integer")
  expect_s3_class(got$s, "data.frame")
  expect_equal(got$s$d, 1.5)
})

test_that("a POSIXct inside a struct is normalised rather than left to the session", {
  # The write-side twin of the int64-in-a-struct bug above: normalise_timestamps()
  # relabelled top-level columns only, so a naive POSIXct one level down reached
  # nanoarrow as the *session's* zone and create_table died with "Unsupported
  # Arrow data type: Timestamp(us, \"America/Chicago\")" -- on a data frame that
  # works unchanged on a machine set to UTC.
  withr::local_timezone("America/Chicago")

  catalog <- local_namespace()
  naive <- as.POSIXct("2024-06-15 08:00:00")
  events <- data.frame(id = 1L)
  events$meta <- data.frame(seen = naive)

  tbl <- icebergr_create_table(catalog, "db.nested_ts", events)
  expect_equal(icebergr_schema(tbl)$type, c("int", "struct<seen: timestamptz>"))

  tbl <- icebergr_append(tbl, events)
  got <- icebergr_collect(tbl)
  expect_equal(as.numeric(got$meta$seen), as.numeric(naive))
})

test_that("a timestamp inside a struct comes back labelled UTC, not +00:00", {
  # And the read-side twin: canonicalise_utc() also stopped at the top level, so
  # a nested timestamptz kept iceberg-rust's "+00:00" and comparing it against an
  # ordinary UTC POSIXct warned "'tzone' attributes are inconsistent" -- the very
  # warning that function exists to prevent.
  catalog <- local_namespace()
  cutoff <- as.POSIXct("2024-06-15 12:00:00", tz = "UTC")
  events <- data.frame(id = 1:2L)
  events$meta <- data.frame(seen = cutoff + c(-3600, 3600))

  tbl <- seed_table(catalog, "db.nested_ts", events)
  got <- icebergr_collect(tbl)

  expect_equal(attr(got$meta$seen, "tzone"), "UTC")
  expect_no_warning(got$meta$seen >= cutoff)
  expect_equal(sum(got$meta$seen >= cutoff), 1L)
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

test_that("a nested struct column round trips, and its type reads as itself", {
  catalog <- local_namespace()
  schema <- nanoarrow::na_struct(list(
    id = nanoarrow::na_int32(),
    loc = nanoarrow::na_struct(list(
      lat = nanoarrow::na_double(),
      lon = nanoarrow::na_double()
    ))
  ))
  tbl <- icebergr_create_table(catalog, "db.nested", schema)

  # iceberg-rust's own Display runs a struct's child types together with no names
  # and no separator, so this column read "struct<doubledouble>" -- which looks
  # like a type called "doubledouble".
  expect_equal(
    icebergr_schema(tbl)$type,
    c("int", "struct<lat: double, lon: double>")
  )

  events <- data.frame(id = 1:2L)
  events$loc <- data.frame(lat = c(1.5, 2.5), lon = c(3.5, 4.5))
  tbl <- icebergr_append(tbl, events)

  got <- icebergr_collect(tbl)
  got <- got[order(got$id), ]
  expect_equal(nrow(got), 2L)
  # A struct arrives as a data frame column.
  expect_s3_class(got$loc, "data.frame")
  expect_equal(got$loc$lat, c(1.5, 2.5))
})

test_that("a list column round trips, and a map column can be created", {
  # A bare R list has no Arrow type nanoarrow can infer, so building a list
  # column at all needs vctrs::list_of. That is what the type-fidelity table
  # documents, so it is what the test uses.
  skip_if_not_installed("vctrs")
  catalog <- local_namespace()

  tbl <- icebergr_create_table(catalog, "db.lists", nanoarrow::na_struct(list(
    id = nanoarrow::na_int32(),
    tags = nanoarrow::na_list(nanoarrow::na_int32())
  )))
  expect_equal(icebergr_schema(tbl)$type, c("int", "list<int>"))

  events <- data.frame(id = 1:2L)
  events$tags <- vctrs::list_of(c(1L, 2L), c(3L))
  tbl <- icebergr_append(tbl, events)

  got <- icebergr_collect(tbl)
  got <- got[order(got$id), ]
  expect_equal(nrow(got), 2L)
  # The type-fidelity table promises it comes back *as a list_of*, not merely as
  # something whose elements are right, so the class is part of the claim.
  expect_s3_class(got$tags, "vctrs_list_of")
  expect_equal(as.integer(got$tags[[1L]]), c(1L, 2L))
  expect_equal(as.integer(got$tags[[2L]]), 3L)

  # A map's *schema* is fine, and renders as itself. Writing map values is not
  # tested because nanoarrow cannot build a map array without the arrow package,
  # which is not a dependency -- and that is the honest extent of the support the
  # feature matrix claims.
  map_tbl <- icebergr_create_table(catalog, "db.maps", nanoarrow::na_struct(list(
    id = nanoarrow::na_int32(),
    # The key type has to be built non-nullable or nanoarrow's own validator
    # rejects the schema it just constructed.
    attrs = nanoarrow::na_map(nanoarrow::na_string(nullable = FALSE), nanoarrow::na_int32())
  )))
  expect_equal(icebergr_schema(map_tbl)$type, c("int", "map<string, int>"))
})

test_that("a nested field cannot be pushed down, and is told so plainly", {
  catalog <- local_namespace()
  schema <- nanoarrow::na_struct(list(
    id = nanoarrow::na_int32(),
    loc = nanoarrow::na_struct(list(lat = nanoarrow::na_double()))
  ))
  tbl <- icebergr_create_table(catalog, "db.nested", schema)
  events <- data.frame(id = 1L)
  events$loc <- data.frame(lat = 1.5)
  tbl <- icebergr_append(tbl, events)

  # Filtering on the struct itself used to advise filtering "on a nested field by
  # its full path", which cannot work by any route: iceberg-rust binds the dotted
  # path but then cannot plan the scan, and refuses to project one outright.
  err <- tryCatch(
    icebergr_collect(icebergr_scan(tbl, filter = loc > 1)),
    error = conditionMessage
  )
  expect_match(err, "primitive columns")
  expect_match(err, "cannot be pushed down at all")
  # The type in the message is rendered readably too.
  expect_match(err, "struct<lat: double>", fixed = TRUE)

  # Selecting one names the real limitation rather than "not in the table".
  expect_error(
    icebergr_scan(tbl, select = "loc.lat"),
    "cannot project a nested field"
  )
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
