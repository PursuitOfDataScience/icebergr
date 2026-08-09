# An error from Rust must reach R as an ordinary R condition, and nothing else.
#
# extendr turns an `Err` returned by a binding into a panic, catches it, and
# re-raises it as an R error. The default Rust panic hook writes a "thread
# panicked at ..." banner to file descriptor 2 on the way past, which R cannot
# see, catch or suppress: it just appears next to the real error looking like a
# crash. R/zzz.R installs a hook that silences that one case.

test_that("a Rust-side failure is a catchable R error", {
  catalog <- local_namespace()

  expect_error(icebergr_table(catalog, "db.absent"), "could not open table")
  # Caught, so nothing escaped as a condition R could not handle.
  expect_no_error(
    tryCatch(icebergr_table(catalog, "db.absent"), error = function(e) NULL)
  )
})

test_that("an ordinary error prints no Rust panic banner on stderr", {
  # Needs a subprocess: the banner goes to the process's own file descriptor 2,
  # not through any R connection, so it cannot be captured in-process.
  skip_on_cran()
  skip_on_os("windows")

  script <- tempfile(fileext = ".R")
  writeLines(
    c(
      sprintf(".libPaths(%s)", deparse(.libPaths())),
      "library(icebergr)",
      "warehouse <- tempfile('warehouse'); dir.create(warehouse)",
      "catalog <- icebergr_catalog('memory', warehouse = warehouse)",
      "icebergr_create_namespace(catalog, 'db')",
      "try(icebergr_table(catalog, 'db.absent'), silent = TRUE)",
      "invisible(NULL)"
    ),
    script
  )
  withr::defer(unlink(script))

  output <- suppressWarnings(system2(
    file.path(R.home("bin"), "Rscript"),
    c("--vanilla", shQuote(script)),
    stdout = TRUE, stderr = TRUE
  ))
  output <- paste(output, collapse = "\n")

  expect_false(grepl("panicked at", output, fixed = TRUE))
})
