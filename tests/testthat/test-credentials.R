# Credential handling: what leaves the process, and what never should.
#
# Each of these guards a finding from the review sweep in #2. They are unit
# tests on the predicates rather than integration tests, because the failure
# mode is "a credential went somewhere" and there is no safe way to stage that.

test_that("a cleartext endpoint is recognised, and loopback is not", {
  expect_true(sends_in_cleartext("http://catalog.internal/v1"))
  expect_true(sends_in_cleartext("http://user:pw@catalog.internal/v1"))
  expect_false(sends_in_cleartext("https://catalog.internal/v1"))

  # Development against a local catalog is the ordinary case and needs no
  # exemption.
  expect_false(sends_in_cleartext("http://localhost:8181/v1"))
  expect_false(sends_in_cleartext("http://127.0.0.1:8181/v1"))
  expect_false(sends_in_cleartext("http://[::1]:8181/v1"))

  # A host that merely starts with "localhost" is a different host.
  expect_true(sends_in_cleartext("http://localhost.evil.example/v1"))

  expect_false(sends_in_cleartext(NULL))
  expect_false(sends_in_cleartext(""))
  # No scheme at all is iceberg-rust's complaint to make, not ours.
  expect_false(sends_in_cleartext("catalog.internal/v1"))
})

test_that("a credential over http is refused, and the escape hatch works", {
  props <- list(uri = "http://catalog.internal/v1", token = "s3cr3t")

  expect_error(check_credential_transport(props), "unencrypted")
  # The message names the property, never its value.
  err <- tryCatch(check_credential_transport(props), error = function(e) e)
  expect_true(any(grepl("token", conditionMessage(err))))
  expect_false(any(grepl("s3cr3t", conditionMessage(err))))

  withr::with_envvar(c(ICEBERGR_ALLOW_INSECURE_CREDENTIALS = "true"), {
    expect_null(check_credential_transport(props))
  })
})

test_that("the escape hatch accepts what people actually type", {
  # as.logical() maps "true"/"T" and returns NA for "1", "yes" and "on" -- the
  # forms a shell profile or a CI file is most likely to hold. Reading those as
  # "not set" would make a documented escape hatch look broken.
  for (yes in c("true", "TRUE", "T", "1", "yes", "on", " 1 ")) {
    withr::with_envvar(c(ICEBERGR_ALLOW_INSECURE_CREDENTIALS = yes), {
      expect_null(
        check_credential_transport(list(uri = "http://c/v1", token = "t")),
        info = yes
      )
    })
  }
  for (no in c("false", "0", "no", "off", "")) {
    withr::with_envvar(c(ICEBERGR_ALLOW_INSECURE_CREDENTIALS = no), {
      expect_error(
        check_credential_transport(list(uri = "http://c/v1", token = "t")),
        "unencrypted"
      )
    })
  }
})

test_that("the transport check only fires when a credential is present", {
  # No credential: an http catalog is the user's business.
  expect_null(check_credential_transport(list(uri = "http://catalog/v1")))
  # Credential over https: fine.
  expect_null(check_credential_transport(
    list(uri = "https://catalog/v1", token = "t")
  ))
  # The OAuth2 endpoint is checked too, not just `uri`.
  expect_error(
    check_credential_transport(list(
      uri = "https://catalog/v1",
      `oauth2-server-uri` = "http://idp.internal/token",
      credential = "id:secret"
    )),
    "unencrypted"
  )
})

test_that("ambient AWS_* credentials reach only object-storage connections", {
  vars <- c(AWS_ACCESS_KEY_ID = "AKIA", AWS_SECRET_ACCESS_KEY = "shh")

  withr::with_envvar(vars, {
    # A REST catalog with no object storage in sight has no use for them, and a
    # third-party catalog can nominate its own s3.endpoint.
    plain <- properties_from_env("rest", "auto", NULL)
    expect_null(plain[["s3.access-key-id"]])

    # Asked for outright.
    expect_identical(
      properties_from_env("rest", "s3", NULL)[["s3.access-key-id"]], "AKIA"
    )
    # Glue implies S3.
    expect_identical(
      properties_from_env("glue", "auto", NULL)[["s3.access-key-id"]], "AKIA"
    )
    # Inferred from the warehouse.
    expect_identical(
      properties_from_env("memory", "auto", "s3://bucket/wh")[["s3.access-key-id"]],
      "AKIA"
    )
    # A local warehouse is not object storage.
    expect_null(properties_from_env("memory", "auto", "/tmp/wh")[["s3.access-key-id"]])
    # An explicit "local" overrides the inference.
    expect_null(properties_from_env("glue", "local", NULL)[["s3.access-key-id"]])
  })
})

test_that("the ICEBERGR_S3_* variables are honoured regardless of storage", {
  # These are an explicit instruction, unlike the ambient AWS_* ones.
  withr::with_envvar(c(ICEBERGR_S3_ACCESS_KEY_ID = "explicit"), {
    expect_identical(
      properties_from_env("rest", "auto", NULL)[["s3.access-key-id"]], "explicit"
    )
  })
})

test_that("printing a catalog does not print a password in its uri", {
  out <- redact_userinfo("https://svc:s3cr3t@catalog.example.com/v1")
  expect_false(grepl("s3cr3t", out))
  expect_identical(out, "https://<redacted>@catalog.example.com/v1")

  # A uri without userinfo is left exactly as it was.
  expect_identical(
    redact_userinfo("https://catalog.example.com/v1"),
    "https://catalog.example.com/v1"
  )
  # A path containing an @ is not userinfo.
  expect_identical(
    redact_userinfo("https://catalog/v1/tables/a@b"),
    "https://catalog/v1/tables/a@b"
  )
})

test_that("loopback is recognised in any case, and across 127.0.0.0/8", {
  # A host name is case-insensitive, so this was refused as though it left the
  # machine.
  expect_false(sends_in_cleartext("http://LOCALHOST:8181/v1"))
  expect_false(sends_in_cleartext("http://LocalHost/v1"))
  expect_false(sends_in_cleartext("http://127.0.0.2:8181/v1"))
  expect_false(sends_in_cleartext("http://127.255.255.254/v1"))
  # Near misses are still remote.
  expect_true(sends_in_cleartext("http://128.0.0.1/v1"))
  expect_true(sends_in_cleartext("http://127.0.0.1.evil.example/v1"))
})

test_that("a credential in a header property counts as a credential", {
  # iceberg-rust sends every `header.*` property as an HTTP header, so this is
  # a bearer token by another route, and it went out over http unchallenged.
  expect_true(is_secret_prop("header.Authorization"))
  expect_true(is_secret_prop("header.authorization"))
  expect_true(is_secret_prop("header.X-Api-Key"))
  expect_false(is_secret_prop("header.X-Iceberg-Access-Delegation"))
  expect_false(is_secret_prop("header.Authorization-Hint"))

  expect_error(
    check_credential_transport(list(
      uri = "http://catalog.internal/v1", `header.Authorization` = "Bearer x"
    )),
    "unencrypted"
  )
  expect_null(check_credential_transport(list(
    uri = "http://catalog.internal/v1", `header.X-Iceberg-Access-Delegation` = "vended-credentials"
  )))
})

test_that("a credential passed through ... gets advice it can follow", {
  # "Set it in the environment" was the advice for every key without an
  # ICEBERGR_* variable of its own, which is advice those keys cannot follow.
  expect_warning(
    icebergr_catalog(
      "rest",
      uri = "https://catalog.example.com", `header.Authorization` = "Bearer x"
    ),
    "ICEBERGR_REST_TOKEN"
  )
  expect_warning(
    icebergr_catalog(
      "rest",
      uri = "https://catalog.example.com", `adls.sas-token` = "x"
    ),
    "Sys.getenv"
  )
})
