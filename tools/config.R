# Generate src/Makevars{,.win} from the .in templates.
#
# The substitutions decide five things:
#   * whether the build unpacks the vendored crates,
#   * whether cargo may reach the network (it may not, when building for CRAN),
#   * whether we build release or debug,
#   * whether the target directory is cleaned afterwards,
#   * which optional Cargo features are compiled in.

source("tools/msrv.R")

vendor_exists <- file.exists("src/rust/vendor.tar.xz")

# Read as a flag, not as "is it set at all". `NOT_CRAN=false` is a value R
# tooling really does pass -- devtools::check() sets exactly that -- and treating
# any non-empty string as TRUE turned a --as-cran check into a networked,
# unrestricted build, which is the one thing this switch exists to prevent. An
# unrecognised value is read as TRUE, so "1", "yes" and "true" all keep working.
as_flag <- function(name) {
  value <- tolower(trimws(Sys.getenv(name)))
  nzchar(value) && !value %in% c("false", "f", "no", "n", "0", "off")
}

is_not_cran <- as_flag("NOT_CRAN")
is_debug <- as_flag("DEBUG")

if (is_debug) {
  # CRAN builds are always release builds, so a debug build implies NOT_CRAN.
  is_not_cran <- TRUE
  message("Creating DEBUG build.")
}

if (!is_not_cran) {
  message("Building for CRAN.")
  if (!vendor_exists) {
    message(paste(
      c(
        "",
        "NOTE: src/rust/vendor.tar.xz was not found, so cargo will be allowed",
        "to resolve dependencies from the network. That is fine for a local",
        "install but is not permitted for a CRAN build. Run",
        "`Rscript tools/vendor.R` to produce the vendored archive.",
        ""
      ),
      collapse = "\n"
    ))
  }
}

# Optional backends are off by default because each substantially enlarges the
# dependency tree. ICEBERGR_CARGO_FEATURES is what ?icebergr_catalog, the README
# and the "not compiled in" error all tell users to set, so it has to reach
# cargo from here -- nothing else in the build reads it.
env_features <- trimws(Sys.getenv("ICEBERGR_CARGO_FEATURES"))
.features <- if (nzchar(env_features)) {
  # Accept "s3,glue" and "s3 glue" alike; cargo wants one comma-separated list.
  parts <- unique(trimws(unlist(strsplit(env_features, "[,[:space:]]+"))))
  parts <- parts[nzchar(parts)]
  known <- c("s3", "glue")
  unknown <- setdiff(parts, known)
  if (length(unknown)) {
    stop(
      "Unknown ICEBERGR_CARGO_FEATURES value(s): ",
      paste(unknown, collapse = ", "),
      ". Known features are: ", paste(known, collapse = ", "), "."
    )
  }
  message("Building with Cargo features: ", paste(parts, collapse = ", "))
  paste("--features", paste(parts, collapse = ","))
} else {
  ""
}

# Whether the build reads vendor.tar.xz, which is also what decides whether
# cargo may reach the network.
#
# The archive holds only the crates a *default* build compiles. Everything else
# in Cargo.lock is in there as a manifest and nothing more, because CRAN's 10 MB
# tarball guidance leaves no room for the ~100 additional crates -- the AWS SDK
# and the whole of AWS-LC among them -- that s3 and glue drag in. Cargo replaces
# the crates.io source wholesale when a directory source is configured, so it
# cannot fetch just the missing few: a feature build has to ignore the archive
# entirely and resolve from crates.io. Hence the third condition, without which
# `ICEBERGR_CARGO_FEATURES=glue R CMD INSTALL` would fail deep inside a compile
# rather than simply going to the network for what it needs.
use_vendor <- !is_not_cran && vendor_exists && !nzchar(env_features)
if (!is_not_cran && vendor_exists && nzchar(env_features)) {
  message(paste(
    c(
      "",
      "NOTE: the vendored sources cover the default build only, so the optional",
      "backend(s) requested through ICEBERGR_CARGO_FEATURES will be resolved",
      "from crates.io. This build therefore needs network access.",
      ""
    ),
    collapse = "\n"
  ))
}

# Only restrict cargo when we are actually building from the vendored sources.
# `-j 2` keeps us inside CRAN's limit on parallelism, which cargo would
# otherwise blow past by defaulting to the number of logical CPUs.
.cran_flags <- if (use_vendor) "-j 2 --offline" else ""

# rustls-native-certs reads the macOS system trust store through the Security
# framework, and reqwest's proxy detection pulls in SystemConfiguration. Decided
# here rather than with `ifeq` in the template, so that the generated Makevars
# stays free of the GNU make extensions R CMD check warns about.
.pkg_libs_extra <- if (identical(Sys.info()[["sysname"]], "Darwin")) {
  "-framework Security -framework CoreFoundation -framework SystemConfiguration"
} else {
  ""
}

# cargo compiles the C inside vendored crates (zstd, aws-lc's assembly) against
# whatever SDK is installed. When that is newer than the deployment target R
# itself was built for -- routine on macOS, where the SDK runs ahead of the R
# binary -- the linker emits "was built for newer 'macOS' version" for every
# object file, and R CMD check turns that into an install WARNING.
#
# The warning is one-directional: it fires only when an object targets a
# *newer* OS than the link does. Building for an older one is always accepted.
# So the target does not have to be guessed exactly -- it only has to be no
# newer than R's.
#
# R records its own in etc/Makeconf, so prefer that. When the flag is absent
# there -- in which case R is taking clang's SDK-derived default and there is no
# number to read -- fall back to the floor for the architecture, which is what
# the CRAN builds of R use anyway: 11.0 for arm64 (macOS 11 is the first release
# that ran on it at all) and 10.13 for x86_64.
.macos_export <- ""
if (identical(Sys.info()[["sysname"]], "Darwin")) {
  makeconf <- file.path(R.home("etc"), "Makeconf")
  target <- if (file.exists(makeconf)) {
    flags <- readLines(makeconf, warn = FALSE)
    found <- unlist(regmatches(
      flags,
      regexpr("-mmacosx-version-min=[0-9][0-9.]*", flags)
    ))
    if (length(found)) sub("^-mmacosx-version-min=", "", found[[1L]]) else ""
  } else {
    ""
  }
  if (!nzchar(target)) {
    arch <- Sys.info()[["machine"]]
    target <- if (identical(arch, "arm64") || identical(arch, "aarch64")) {
      "11.0"
    } else {
      "10.13"
    }
    message(
      "R states no macOS deployment target; using the ", arch, " floor instead."
    )
  }
  if (nzchar(target)) {
    message("Building Rust against MACOSX_DEPLOYMENT_TARGET=", target, ".")
    # No trailing backslash: the template supplies the line continuation, so an
    # empty substitution still leaves the recipe as one shell invocation.
    .macos_export <- paste0("export MACOSX_DEPLOYMENT_TARGET=", target, " &&")
  }
}

.profile <- if (is_debug) "" else "--release"
.clean_targets <- if (is_debug) "" else "$(TARGET_DIR)"
.libdir <- if (is_debug) "debug" else "release"

is_windows <- .Platform[["OS.type"]] == "windows"

mv_fp <- if (is_windows) "src/Makevars.win.in" else "src/Makevars.in"
mv_ofp <- if (is_windows) "src/Makevars.win" else "src/Makevars"

if (file.exists(mv_ofp)) {
  message("Cleaning previous `", mv_ofp, "`.")
  invisible(file.remove(mv_ofp))
}

mv_txt <- readLines(mv_fp, warn = FALSE)

new_txt <- gsub("@CRAN_FLAGS@", .cran_flags, mv_txt)
new_txt <- gsub("@FEATURES@", .features, new_txt)
new_txt <- gsub("@USE_VENDOR@", if (use_vendor) "true" else "false", new_txt)
new_txt <- gsub("@PKG_LIBS_EXTRA@", .pkg_libs_extra, new_txt)
new_txt <- gsub("@MACOS_EXPORT@", .macos_export, new_txt)
new_txt <- gsub("@PROFILE@", .profile, new_txt)
new_txt <- gsub("@CLEAN_TARGET@", .clean_targets, new_txt)
new_txt <- gsub("@LIBDIR@", .libdir, new_txt)

message("Writing `", mv_ofp, "`.")
con <- file(mv_ofp, open = "wb")
writeLines(new_txt, con, sep = "\n")
close(con)

message("`tools/config.R` has finished.")
