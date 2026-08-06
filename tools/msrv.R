# Verify that a Rust toolchain is present and new enough before we hand off to
# cargo. Failing here, with an actionable message, is much friendlier than
# failing several minutes into a compile with a syntax error from a newer
# edition.
#
# The required version is read from SystemRequirements so that DESCRIPTION stays
# the single source of truth.

desc <- read.dcf("DESCRIPTION")

if (!"SystemRequirements" %in% colnames(desc)) {
  stop(paste(
    c(
      "`SystemRequirements` not found in `DESCRIPTION`.",
      "Please specify `SystemRequirements: Cargo (Rust's package manager), rustc >= 1.94`"
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
  "'iceberg' compiles Apache Iceberg's Rust implementation, so a Rust",
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
  paste("'iceberg' requires", rustc_req, "or newer. Install it from:"),
  "",
  "  https://www.rust-lang.org/tools/install",
  "-------------------------------------------------------------------------"
)

# rustup installs into ~/.cargo/bin, which is not always on the PATH that R
# sees, particularly under RStudio or a system R launched from a desktop
# session.
Sys.setenv(PATH = paste0(
  Sys.getenv("PATH"), ":", file.path(Sys.getenv("HOME"), ".cargo", "bin")
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
        "'iceberg' bundles Apache Iceberg's Rust implementation, which uses",
        "Rust edition 2024 and tracks a rolling minimum version. Please run",
        "`rustup update stable`, or install a newer toolchain from",
        "https://www.rust-lang.org/tools/install.",
        "---------------------------------------------------------------------"
      ),
      collapse = "\n"
    ), msrv, current))
  }
}

message(sprintf("Using %s\nUsing %s", cargo_version, rustc_version))
