# The feature matrix is part of the package's contract: it is how a user finds
# out what is unsupported without discovering it at runtime.

test_that("spec support reports versions, catalogs and features", {
  support <- icebergr_spec_support()

  expect_s3_class(support, "icebergr_spec_support")
  expect_equal(support$spec_versions, c(1L, 2L))
  expect_equal(support$iceberg_rust_version, "0.10.0")
  expect_true(all(c("rest", "memory") %in% support$catalogs))
  expect_s3_class(support$features, "tbl_df")
  expect_setequal(names(support$features), c("feature", "supported", "reason"))
})

test_that("every unsupported or unavailable feature gives a reason", {
  features <- icebergr_spec_support()$features

  # An unsupported feature with no explanation is not much use to anyone.
  needs_reason <- features[!isTRUE_vec(features$supported), ]
  expect_true(all(nzchar(needs_reason$reason)))
  expect_false(any(is.na(needs_reason$reason)))
})

test_that("the things this version deliberately omits are marked unsupported", {
  features <- icebergr_spec_support()$features
  unsupported <- features$feature[isFALSE_vec(features$supported)]

  expect_true("MERGE / upsert" %in% unsupported)
  expect_true("Row-level deletes (write)" %in% unsupported)
  expect_true("Schema evolution" %in% unsupported)
  expect_true("Partition evolution" %in% unsupported)
  expect_true("Compaction / maintenance" %in% unsupported)
  expect_true("dbplyr lazy verbs" %in% unsupported)
  # Not our omission, but upstream's, and worth stating plainly.
  expect_true("Hadoop/filesystem catalog" %in% unsupported)
  expect_true("Row limit pushdown" %in% unsupported)
})

test_that("the core reads and writes are marked supported", {
  features <- icebergr_spec_support()$features
  supported <- features$feature[isTRUE_vec(features$supported)]

  expect_true("Read table (Arrow)" %in% supported)
  expect_true("Predicate pushdown" %in% supported)
  expect_true("Projection pushdown" %in% supported)
  expect_true("Snapshot time travel" %in% supported)
  expect_true("Append writes" %in% supported)
})

test_that("build-dependent features resolve to TRUE or FALSE, never NA", {
  support <- icebergr_spec_support()
  features <- support$features

  glue <- features$supported[features$feature == "AWS Glue catalog"]
  s3 <- features$supported[features$feature == "Object storage (S3)"]

  # These start as NA in the table and must be resolved against the real build.
  expect_false(is.na(glue))
  expect_false(is.na(s3))
  expect_equal(glue, "glue" %in% support$cargo_features)
  expect_equal(s3, "s3" %in% support$cargo_features)
})

test_that("spec support prints without error", {
  expect_output(print(icebergr_spec_support()), "icebergr_spec_support")
})
