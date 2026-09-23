# Verify that a Rust toolchain is present and new enough before we hand off to
# cargo. Failing here, with an actionable message, is much friendlier than
# failing several minutes into a compile with a syntax error from a newer
# edition.
#
# The required version is read from SystemRequirements so that DESCRIPTION stays
# the single source of truth.
#
# This is the *only* version gate: src/Makevars{,.win} pass
# --ignore-rust-version to cargo, because four crates in the tree declare
# rust-version = "1.94" under iceberg-rust's rolling-MSRV policy without needing
# it, and cargo would otherwise refuse to build on the 1.92 toolchain CRAN's
# Windows farm carries. So the floor in DESCRIPTION has to be a version the
# package has really been checked against, not an aspiration.

desc <- read.dcf("DESCRIPTION")

if (!"SystemRequirements" %in% colnames(desc)) {
  stop(paste(
    c(
      "`SystemRequirements` not found in `DESCRIPTION`.",
      "Please specify `SystemRequirements: Cargo (Rust's package manager), rustc >= 1.92`"
    ),
    collapse = "\n"
  ))
}

sysreqs <- desc[, "SystemRequirements"]

if (!grepl("cargo", sysreqs, ignore.case = TRUE)) {
  stop("You must specify `Cargo (Rust's package manager)` in `SystemRequirements`.")
}

if (!grepl("rustc", sysreqs, ignore.case = TRUE)) {
  stop("You must specify `rustc` in `SystemRequirements`.")
}

parts <- strsplit(sysreqs, ", ")[[1]]
# Case-insensitive, like the presence check above: otherwise "Rustc >= 1.92"
# passed that check and then matched nothing here.
rustc_req <- parts[grepl("rustc", parts, ignore.case = TRUE)]

no_cargo_msg <- c(
  "--------------------------- [CARGO NOT FOUND] ---------------------------",
  "The 'cargo' command was not found on the PATH.",
  "",
  "'icebergr' compiles Apache Iceberg's Rust implementation, so a Rust",
  "toolchain is required to install it from source. Install one from:",
  "",
  "  https://rust-lang.org/tools/install/",
  "",
  "Your OS package manager may also provide it, but distribution packages",
  "are frequently older than the version this package needs:",
  "  - Debian/Ubuntu: apt-get install cargo",
  "  - Fedora/CentOS: dnf install cargo",
  "  - macOS:         brew install rust",
  "-------------------------------------------------------------------------"
)

no_rustc_msg <- c(
  "---------------------------- [RUST NOT FOUND] ---------------------------",
  "The 'rustc' compiler was not found on the PATH.",
  "",
  paste("'icebergr' requires", rustc_req, "or newer. Install it from:"),
  "",
  "  https://rust-lang.org/tools/install/",
  "-------------------------------------------------------------------------"
)

# rustup installs into ~/.cargo/bin, which is not always on the PATH that R
# sees, particularly under RStudio or a system R launched from a desktop
# session. The separator is ";" on Windows, where configure.win runs this too;
# hard-coding ":" would corrupt the PATH rather than extend it.
Sys.setenv(PATH = paste(
  Sys.getenv("PATH"),
  file.path(Sys.getenv("HOME"), ".cargo", "bin"),
  sep = .Platform$path.sep
))

rustc_version <- tryCatch(
  system("rustc --version", intern = TRUE),
  error = function(e) stop(paste(no_rustc_msg, collapse = "\n")),
  warning = function(w) stop(paste(no_rustc_msg, collapse = "\n"))
)

cargo_version <- tryCatch(
  system("cargo --version", intern = TRUE),
  error = function(e) stop(paste(no_cargo_msg, collapse = "\n")),
  warning = function(w) stop(paste(no_cargo_msg, collapse = "\n"))
)

extract_semver <- function(ver) {
  # One string, whatever arrives: `if ()` on a zero-length or longer condition
  # is an error, which is how a DESCRIPTION naming rustc twice, or not in a form
  # the line above finds, crashed here before reaching the readable message
  # below that exists for exactly those cases.
  ver <- paste(ver, collapse = " ")
  if (grepl("\\d+\\.\\d+(\\.\\d+)?", ver)) {
    sub(".*?(\\d+\\.\\d+(\\.\\d+)?).*", "\\1", ver)
  } else {
    NA_character_
  }
}

msrv <- extract_semver(rustc_req)
current <- extract_semver(rustc_version)

# An unreadable floor is a mistake in DESCRIPTION, which is ours, so it stops
# here. Previously both this and an unreadable `rustc --version` just skipped
# the comparison, which meant a typo in SystemRequirements silently removed the
# only version gate the package has and let any toolchain through. The CI job
# that reads the same field already exits 1 when it cannot find
# `rustc >= <version>`; this now agrees with it. Note "rustc >= 2" is one of the
# strings that used to parse to NA.
if (length(rustc_req) != 1L || is.na(msrv)) {
  stop(paste(
    c(
      "",
      "------------------- [UNREADABLE RUST REQUIREMENT] -------------------",
      "Could not read a minimum version from the `rustc` entry in",
      "`SystemRequirements`:",
      "",
      paste("  ", if (length(rustc_req)) paste(rustc_req, collapse = " | ") else "<none>"),
      "",
      "It has to look like `rustc >= 1.92`, with major and minor at least.",
      "---------------------------------------------------------------------"
    ),
    collapse = "\n"
  ))
}

# The installed version string is the toolchain's to format, not ours. If a
# future rustc prints something this cannot parse, say so and carry on rather
# than refusing to install over a cosmetic change: cargo still enforces what it
# needs, and a warning is recoverable where a hard stop is not.
if (is.na(current)) {
  warning(sprintf(
    "Could not read a version from `rustc --version` (%s); skipping the %s check.",
    paste(rustc_version, collapse = " "), msrv
  ))
}

if (!is.na(current)) {
  if (utils::compareVersion(msrv, current) == 1L) {
    stop(sprintf(paste(
      c(
        "",
        "--------------------- [UNSUPPORTED RUST VERSION] --------------------",
        "- Minimum supported Rust version is %s.",
        "- Installed Rust version is %s.",
        "",
        "'icebergr' bundles Apache Iceberg's Rust implementation, which is",
        "written against Rust edition 2024. Please run `rustup update stable`,",
        "or install a newer toolchain from",
        "https://rust-lang.org/tools/install/.",
        "---------------------------------------------------------------------"
      ),
      collapse = "\n"
    ), msrv, current))
  }
}

message(sprintf("Using %s\nUsing %s", cargo_version, rustc_version))
