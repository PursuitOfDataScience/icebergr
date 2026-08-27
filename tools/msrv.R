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
rustc_req <- parts[grepl("rustc", parts)]

no_cargo_msg <- c(
  "--------------------------- [CARGO NOT FOUND] ---------------------------",
  "The 'cargo' command was not found on the PATH.",
  "",
  "'icebergr' compiles Apache Iceberg's Rust implementation, so a Rust",
  "toolchain is required to install it from source. Install one from:",
  "",
  "  https://www.rust-lang.org/tools/install",
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
  "  https://www.rust-lang.org/tools/install",
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
  if (grepl("\\d+\\.\\d+(\\.\\d+)?", ver)) {
    sub(".*?(\\d+\\.\\d+(\\.\\d+)?).*", "\\1", ver)
  } else {
    NA_character_
  }
}

msrv <- extract_semver(rustc_req)
current <- extract_semver(rustc_version)

if (!is.na(msrv) && !is.na(current)) {
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
        "https://www.rust-lang.org/tools/install.",
        "---------------------------------------------------------------------"
      ),
      collapse = "\n"
    ), msrv, current))
  }
}

message(sprintf("Using %s\nUsing %s", cargo_version, rustc_version))
