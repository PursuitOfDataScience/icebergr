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

test_that("an ordering comparison on a Date or timestamp returns the right rows", {
  # The %in% test above covers set membership, and test-filter.R covers what
  # `day ==` and `ts >` emit as JSON. Neither pins the *rows* an ordering
  # comparison returns, which is what catches a datum built correctly and then
  # bound with the comparison the wrong way round: `>` answering `<` returns the
  # complement, silently, with every row still a real row.
  #
  # Asserted against a partition of the fixture, so a flipped operator cannot
  # coincide with the right answer.
  catalog <- local_namespace()
  days <- as.Date(c("2024-01-01", "2024-02-01", "2024-03-01", "2024-04-01"))
  stamps <- as.POSIXct(paste(days, "00:00:00"), tz = "UTC")
  events <- data.frame(id = 1:4L, day = days, ts = stamps)
  tbl <- seed_table(catalog, "db.events", events)

  cut_day <- days[[2L]]
  expect_setequal(
    icebergr_collect(icebergr_scan(tbl, filter = day > cut_day))$id, c(3L, 4L)
  )
  expect_setequal(
    icebergr_collect(icebergr_scan(tbl, filter = day <= cut_day))$id, c(1L, 2L)
  )

  cut_ts <- stamps[[3L]]
  expect_setequal(
    icebergr_collect(icebergr_scan(tbl, filter = ts >= cut_ts))$id, c(3L, 4L)
  )
  expect_setequal(
    icebergr_collect(icebergr_scan(tbl, filter = ts < cut_ts))$id, c(1L, 2L)
  )

  # The column on the right-hand side has to flip the operator with it.
  expect_setequal(
    icebergr_collect(icebergr_scan(tbl, filter = cut_day < day))$id, c(3L, 4L)
  )
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

  # Every one of these returned zero rows. iceberg-rust 0.10's row-selection
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

test_that("a bound past what a long can hold is refused, not clamped to i64::MAX", {
  skip_if_not_installed("bit64")
  catalog <- local_namespace()
  events <- data.frame(id = 1:2L, big = bit64::as.integer64(c("1", "9223372036854775807")))
  tbl <- seed_table(catalog, "db.big", events)

  # 1e19 is past i64::MAX, and R sends anything past 2^53 as a plain JSON
  # number, so the Rust side reached it as a double. Casting a double to i64
  # *saturates*, so this used to become `big == 9223372036854775807` and return
  # the row holding i64::MAX -- a filter that quietly answered a different
  # question. The 32-bit column has always refused an out-of-range bound; this
  # is the 64-bit one agreeing.
  expect_error(
    icebergr_collect(icebergr_scan(tbl, filter = big == 1e19)),
    "outside the range of a 64-bit integer"
  )
  expect_error(
    icebergr_collect(icebergr_scan(tbl, filter = big > -1e19)),
    "outside the range of a 64-bit integer"
  )

  # A bound that does fit still pushes down, including one past 2^53.
  in_range <- icebergr_collect(icebergr_scan(tbl, filter = big > 1e18))
  expect_equal(as.character(in_range$big), "9223372036854775807")
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

test_that("a timestamp read back from a table matches its own row", {
  # The round trip a user actually makes: read a value, filter on it. The literal
  # used to be truncated to the microsecond below, and the double nanoarrow
  # returns for a microsecond timestamp is below it more often than not, so this
  # found no row for 83% of 200 random instants.
  catalog <- local_namespace()
  set.seed(20240101)
  micros <- sort(sample(1:999999, 40L))
  events <- data.frame(
    id = seq_along(micros),
    ts = as.POSIXct("2024-01-01", tz = "UTC") + micros / 1e6
  )
  tbl <- seed_table(catalog, "db.events", events)
  back <- icebergr_collect(tbl)

  for (i in seq_len(nrow(back))) {
    stamp <- back$ts[[i]]
    expect_identical(
      icebergr_collect(icebergr_scan(tbl, filter = ts == stamp, select = "id"))$id,
      back$id[[i]],
      info = format(stamp, "%OS6")
    )
  }
  # And an ordering comparison puts the boundary row on the right side of it.
  pivot <- back$ts[[20L]]
  expect_setequal(
    icebergr_collect(icebergr_scan(tbl, filter = ts >= pivot, select = "id"))$id,
    back$id[back$ts >= pivot]
  )
})

test_that("comparing two columns is refused rather than half-evaluated", {
  catalog <- local_namespace()
  tbl <- seed_table(catalog, "db.pairs", data.frame(a = 1:5L, b = 5:1L))

  expect_error(icebergr_scan(tbl, filter = a > b), "is a column of the table")
  # A local of the same name used to stand in for column `b`, silently.
  b <- 3L
  expect_error(icebergr_scan(tbl, filter = a > b), "is a column of the table")
  expect_error(icebergr_scan(tbl, filter = a %in% b), "is a column of the table")
})

nan_schema <- function() {
  nanoarrow::na_struct(list(
    id = nanoarrow::na_int32(), i = nanoarrow::na_int32(),
    d = nanoarrow::na_double(), f = nanoarrow::na_float(), s = nanoarrow::na_string()
  ))
}

# A batch holding real NaN and -0.0 values, the way another engine writes them.
# nanoarrow turns an R NaN into a null on the way in, so the value buffers are
# written directly: nulls come from `NA`, everything else, NaN included, is a
# value.
nan_batch <- function(data) {
  is_null <- function(v) is.na(v) & !is.nan(v)
  float_array <- function(v, schema, size) {
    arr <- nanoarrow::as_nanoarrow_array(as.numeric(ifelse(is_null(v), NA, 1)), schema = schema)
    values <- ifelse(is_null(v), 0, v)
    buffer <- if (size == 4L) {
      nanoarrow::as_nanoarrow_buffer(writeBin(values, raw(), size = 4L, endian = "little"))
    } else {
      nanoarrow::as_nanoarrow_buffer(values)
    }
    nanoarrow::nanoarrow_array_modify(arr, list(buffers = list(arr$buffers[[1L]], buffer)))
  }
  batch <- nanoarrow::nanoarrow_array_init(nan_schema())
  nanoarrow::nanoarrow_array_modify(batch, list(
    length = nrow(data),
    children = list(
      id = nanoarrow::as_nanoarrow_array(data$id),
      i = nanoarrow::as_nanoarrow_array(data$i),
      d = float_array(data$d, nanoarrow::na_double(), 8L),
      f = float_array(data$f, nanoarrow::na_float(), 4L),
      s = nanoarrow::as_nanoarrow_array(data$s)
    )
  ))
}

# The table, spread over three data files so that pruning has something to do.
nan_table <- function(catalog, data) {
  tbl <- icebergr_create_table(catalog, "db.values", nan_schema())
  for (part in split(seq_len(nrow(data)), rep(1:3, length.out = nrow(data)))) {
    stream <- nanoarrow::basic_array_stream(list(nan_batch(data[sort(part), ])))
    tbl <- icebergr_append(tbl, stream)
  }
  tbl
}

test_that("NA, NaN and -0.0 mean in a pushed-down filter what they mean in R", {
  catalog <- local_namespace()
  data <- data.frame(
    id = 1:6, i = c(1L, NA, 3L, 4L, 5L, 6L),
    d = c(NaN, 0.5, 2, NaN, -0, NA), f = c(NaN, 0.5, 2, NaN, -0, NA),
    s = c("a", NA, "b", "c", "d", "e")
  )
  tbl <- nan_table(catalog, data)
  ids <- function(scan) sort(icebergr_collect(scan)$id)

  # NaN compares as NA in R. Iceberg's row filter ordered NaN above every
  # number, so `d > 1` returned the NaN in a file it read and not the one in a
  # file its statistics pruned: identical values, different answers.
  expect_equal(ids(icebergr_scan(tbl, filter = d > 1)), 3L)
  expect_equal(ids(icebergr_scan(tbl, filter = f > 1)), 3L)
  expect_equal(ids(icebergr_scan(tbl, filter = !(d <= 1))), 3L)
  expect_equal(ids(icebergr_scan(tbl, filter = d != 2)), c(2L, 5L))
  # is.na() is TRUE for NaN, and is.nan() only for NaN.
  expect_equal(ids(icebergr_scan(tbl, filter = is.na(d))), c(1L, 4L, 6L))
  expect_equal(ids(icebergr_scan(tbl, filter = !is.na(d))), c(2L, 3L, 5L))
  expect_equal(ids(icebergr_scan(tbl, filter = is.nan(d))), c(1L, 4L))
  expect_equal(ids(icebergr_scan(tbl, filter = !is.nan(d))), c(2L, 3L, 5L, 6L))
  # -0.0 is zero. Arrow's total order puts it below 0.0, so `== 0` missed it.
  expect_equal(ids(icebergr_scan(tbl, filter = d == 0)), 5L)
  expect_equal(ids(icebergr_scan(tbl, filter = f >= 0)), c(2L, 3L, 5L))
  expect_equal(ids(icebergr_scan(tbl, filter = d %in% c(0, 2))), c(3L, 5L))
  # %in% is never NA in R, so its negation keeps the missing values; Iceberg's
  # NOT IN of a null is null, and dropped them.
  expect_equal(ids(icebergr_scan(tbl, filter = !(i %in% c(1L, 3L)))), c(2L, 4L, 5L, 6L))
  expect_equal(ids(icebergr_scan(tbl, filter = !(s %in% "a"))), 2:6)
  expect_equal(ids(icebergr_scan(tbl, filter = !(d %in% 2))), c(1L, 2L, 4L, 5L, 6L))
})

test_that("random filters return exactly the rows R's own evaluation does", {
  # The cases above, and every combination of them the grammar below can reach:
  # comparisons, is.na(), is.nan(), %in% and startsWith() over columns holding
  # NA, NaN and both zeros, nested under !, & and |. Before the filter was
  # built in R's logic, 71 of 400 such filters disagreed with R.
  catalog <- local_namespace()
  withr::with_seed(20260923, {
    n <- 48L
    pool <- c(-1.5, -0, 0, 0.5, 2, NA, NaN)
    data <- data.frame(
      id = seq_len(n),
      i = sample(c(1:5, NA), n, TRUE),
      d = sample(pool, n, TRUE),
      f = sample(pool, n, TRUE),
      s = sample(c("apple", "banana", "avocado", NA), n, TRUE)
    )
    tbl <- nan_table(catalog, data)
    back <- icebergr_collect(tbl)

    compare <- function(col, ops, values) {
      call(sample(ops, 1L), as.name(col), values[[sample(length(values), 1L)]])
    }
    pick <- function(values, k) values[sample(length(values), k)]
    numbers <- c(-1.5, 0, -0, 0.5, 2, 1)
    atom <- function() {
      switch(sample(11L, 1L),
        compare("i", c(">", ">=", "<", "<=", "==", "!="), 1:5),
        compare("d", c(">", ">=", "<", "<=", "==", "!="), numbers),
        compare("f", c(">", ">=", "<", "<=", "==", "!="), numbers),
        compare("s", c(">", "<", "==", "!="), c("apple", "b", "avocado")),
        call("is.na", as.name(pick(c("i", "d", "f", "s"), 1L))),
        call("is.nan", as.name(pick(c("d", "f"), 1L))),
        call("%in%", quote(i), pick(1:5, 2L)),
        call("%in%", quote(d), pick(c(-1.5, 0, 2), 2L)),
        call("%in%", quote(f), pick(c(-1.5, 0, 0.5), 2L)),
        call("%in%", quote(s), pick(c("apple", "banana"), 1L)),
        call("startsWith", quote(s), pick(c("a", "b", "av"), 1L))
      )
    }
    generate <- function(depth = 0L) {
      r <- stats::runif(1L)
      if (depth >= 2L || r < 0.45) {
        return(atom())
      }
      if (r < 0.65) {
        return(call("!", generate(depth + 1L)))
      }
      call(if (r < 0.85) "&" else "|", generate(depth + 1L), generate(depth + 1L))
    }

    # All lower-case ASCII, so R's collation and Iceberg's byte order agree.
    withr::with_collate("C", {
      for (k in seq_len(150L)) {
        e <- generate()
        want <- sort(back$id[which(eval(e, back))])
        got <- sort(icebergr_collect(do.call(icebergr_scan, list(tbl, filter = e)))$id)
        expect_identical(got, want, info = deparse1(e))
      }
    })
  })
})

# A table whose first data file predates three of its columns, as one is after
# another engine runs ALTER TABLE ADD COLUMN and then writes more.
evolved_table <- function(env = parent.frame()) {
  warehouse <- withr::local_tempdir("evolved", .local_envir = env)
  catalog <- icebergr_catalog("memory", warehouse = warehouse)
  icebergr_create_namespace(catalog, "db")
  seed_table(catalog, "db.t", data.frame(a = 1:4))
  tbl <- with_schema(
    warehouse, "db.t",
    paste0("[", paste(
      schema_field(1L, "a", "int"), schema_field(2L, "b", "int"),
      schema_field(3L, "s", "string"), schema_field(4L, "f", "double"),
      sep = ","
    ), "]"),
    4L
  )
  icebergr_append(tbl, data.frame(
    a = 5:9, b = c(10L, 20L, NA, 30L, 5L), s = c("xa", "ya", NA, "xb", "b"),
    f = c(0.5, -0, NA, 2, -1.5)
  ))
}

test_that("a filter on a column older files lack keeps the rows R would", {
  # iceberg-rust's row filter answers a predicate on a column a file does not
  # have from a table of constants, and answered TRUE for <, <=, NOT STARTS WITH,
  # NOT IN and NOT NAN. So `b < 15` returned every row of the older file, each
  # with `b` NA, which neither R nor Iceberg's own null rules would.
  tbl <- evolved_table()
  ids <- function(scan) sort(icebergr_collect(scan)$a)

  expect_equal(ids(icebergr_scan(tbl, filter = b < 15L)), c(5L, 9L))
  expect_equal(ids(icebergr_scan(tbl, filter = b <= 15L)), c(5L, 9L))
  expect_equal(ids(icebergr_scan(tbl, filter = !(b > 15L))), c(5L, 9L))
  expect_equal(ids(icebergr_scan(tbl, filter = !(b >= 15L))), c(5L, 9L))
  expect_equal(ids(icebergr_scan(tbl, filter = s < "y")), c(5L, 8L, 9L))
  expect_equal(ids(icebergr_scan(tbl, filter = !startsWith(s, "x"))), c(6L, 9L))
  expect_equal(ids(icebergr_scan(tbl, filter = f < 1)), c(5L, 6L, 9L))
  expect_equal(ids(icebergr_scan(tbl, filter = f != 0)), c(5L, 8L, 9L))
  # Unchanged, and right before too: these already treated the absent column as
  # NA, which is what it reads back as.
  expect_equal(ids(icebergr_scan(tbl, filter = is.na(b))), c(1:4, 7L))
  expect_equal(ids(icebergr_scan(tbl, filter = !(b %in% 10L))), c(1:4, 6:9))
  expect_equal(ids(icebergr_scan(tbl, filter = b > 15L)), c(6L, 8L))
})

test_that("random filters over older files agree with R as well", {
  tbl <- evolved_table()
  back <- icebergr_collect(tbl)
  withr::with_seed(20261005, {
    atom <- function() {
      switch(sample(7L, 1L),
        call(sample(c(">", ">=", "<", "<=", "==", "!="), 1L), quote(b), sample(c(5L, 10L, 25L), 1L)),
        call(sample(c(">", ">=", "<", "<=", "==", "!="), 1L), quote(f), sample(c(-1.5, 0, 1), 1L)),
        call(sample(c(">", "<", "==", "!="), 1L), quote(s), sample(c("b", "xa", "y"), 1L)),
        call(sample(c(">", "<=", "!="), 1L), quote(a), sample(c(2L, 6L), 1L)),
        call("is.na", as.name(sample(c("b", "s", "f"), 1L))),
        call("%in%", quote(b), sample(c(5L, 10L, 30L), 2L)),
        call("startsWith", quote(s), sample(c("x", "y"), 1L))
      )
    }
    generate <- function(depth = 0L) {
      r <- stats::runif(1L)
      if (depth >= 2L || r < 0.45) {
        return(atom())
      }
      if (r < 0.65) {
        return(call("!", generate(depth + 1L)))
      }
      call(if (r < 0.85) "&" else "|", generate(depth + 1L), generate(depth + 1L))
    }
    withr::with_collate("C", {
      for (k in seq_len(100L)) {
        e <- generate()
        want <- sort(back$a[which(eval(e, back))])
        got <- sort(icebergr_collect(do.call(icebergr_scan, list(tbl, filter = e)))$a)
        expect_identical(got, want, info = deparse1(e))
      }
    })
  })
})

test_that("a decimal compares against a value too small or too large for short JSON", {
  # serde_json rewrote both of these with an exponent, "2e-8" and "1e+20", and
  # they were then refused as exponent notation although R had written them
  # out in full. A decimal(18, 8) could not be compared below 1e-5 at all.
  catalog <- local_namespace()
  schema <- nanoarrow::na_struct(list(
    id = nanoarrow::na_int32(),
    rate = nanoarrow::na_decimal128(precision = 18, scale = 8),
    big = nanoarrow::na_decimal128(precision = 38, scale = 2)
  ))
  tbl <- icebergr_create_table(catalog, "db.rates", schema)
  tbl <- icebergr_append(tbl, data.frame(
    id = 1:3, rate = c(0.00000001, 0.00000005, 1), big = c(1, 1e19, 1e21)
  ))
  ids <- function(scan) sort(icebergr_collect(scan)$id)

  expect_equal(ids(icebergr_scan(tbl, filter = rate > 0.00000002)), 2:3)
  expect_equal(ids(icebergr_scan(tbl, filter = rate == 0.00000005)), 2L)
  expect_equal(ids(icebergr_scan(tbl, filter = big > 1e20)), 3L)
  expect_equal(ids(icebergr_scan(tbl, filter = big < 1e20)), 1:2)
})
