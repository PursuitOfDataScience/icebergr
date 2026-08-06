# Produce src/rust/vendor.tar.xz and LICENSE.note.
#
# This needs network access and is therefore never run during an install; it is
# a packaging step, run by a maintainer or by CI before building the tarball.
#
#   Rscript tools/vendor.R
#
# CRAN requires that the vendored sources be compressed with xz and that
# authorship and licensing of every bundled crate be recorded. LICENSE.note is
# the conventional place for the latter.

vendor_dir <- file.path("src", "rust", "vendor")
archive <- file.path("src", "rust", "vendor.tar.xz")
manifest <- file.path("src", "rust", "Cargo.toml")

if (Sys.which("cargo") == "") {
  stop("`cargo` was not found on the PATH.")
}
if (Sys.which("tar") == "") {
  stop("`tar` was not found on the PATH.")
}

# Any stale vendor directory has to go, or removed dependencies linger in the
# archive and the licence inventory.
if (dir.exists(vendor_dir)) {
  message("Removing stale ", vendor_dir)
  unlink(vendor_dir, recursive = TRUE)
}

features <- Sys.getenv("ICEBERG_CARGO_FEATURES")
feature_args <- if (nzchar(features)) {
  c("--features", features)
} else {
  character()
}

message("Vendoring Rust dependencies. This downloads several hundred crates.")
status <- system2(
  "cargo",
  c("vendor", "--versioned-dirs", "--manifest-path", manifest, feature_args, vendor_dir)
)
if (status != 0L) {
  stop("`cargo vendor` failed with status ", status)
}

# Windows-only and other non-target crates still get vendored, and some ship
# large test corpora that inflate the archive without ever being compiled.
# Dropping test fixtures is safe and is what other Rust CRAN packages do.
junk <- list.files(
  vendor_dir,
  pattern = "^(tests?|examples|benches|fuzz|\\.github)$",
  recursive = TRUE,
  include.dirs = TRUE,
  full.names = TRUE
)
junk <- junk[dir.exists(junk)]
if (length(junk)) {
  message("Pruning ", length(junk), " test/example directories from vendor tree.")
  unlink(junk, recursive = TRUE)
}

# `cargo vendor` writes checksums that include the files we just pruned, so they
# have to be neutralised or cargo will refuse to build from the vendor tree.
checksums <- list.files(
  vendor_dir,
  pattern = "^\\.cargo-checksum\\.json$",
  recursive = TRUE,
  full.names = TRUE,
  all.files = TRUE
)
message("Rewriting ", length(checksums), " vendored checksum files.")
for (f in checksums) {
  txt <- readLines(f, warn = FALSE)
  pkg <- sub('.*"package":\\s*("[a-f0-9]+"|null).*', "\\1", paste(txt, collapse = ""))
  if (identical(pkg, paste(txt, collapse = ""))) pkg <- "null"
  writeLines(sprintf('{"files":{},"package":%s}', pkg), f)
}

if (file.exists(archive)) invisible(file.remove(archive))

message("Creating ", archive)
status <- system2(
  "tar",
  c("-cJf", shQuote(archive), "-C", shQuote(file.path("src", "rust")), "vendor")
)
if (status != 0L) {
  stop("`tar` failed with status ", status)
}

size_mb <- round(file.size(archive) / 1024^2, 2)
n_crates <- length(list.dirs(vendor_dir, recursive = FALSE))
message(sprintf(
  "Vendored %d crates into %s (%s MB).", n_crates, archive, format(size_mb)
))
if (size_mb > 10) {
  message(
    "NOTE: CRAN prefers source tarballs under 10 MB. At ", size_mb,
    " MB this needs an explicit exemption request, and is very likely to be\n",
    "refused at this size. See FEASIBILITY.md."
  )
}

# ---- LICENSE.note -----------------------------------------------------------
# Read each vendored crate's own manifest for authors, repository and licence.
# Doing it from the vendor tree rather than from `cargo metadata` means the
# inventory always describes exactly what is shipped.

read_field <- function(lines, field) {
  # Minimal TOML scraping, confined to the [package] table. A real TOML parser
  # would be a heavier dependency than this task warrants.
  start <- grep("^\\s*\\[package\\]\\s*$", lines)
  if (!length(start)) return(NA_character_)
  rest <- lines[(start[1] + 1):length(lines)]
  nxt <- grep("^\\s*\\[", rest)
  if (length(nxt)) rest <- rest[seq_len(nxt[1] - 1)]

  hit <- grep(sprintf("^\\s*%s\\s*=", field), rest)
  if (!length(hit)) return(NA_character_)
  val <- sub(sprintf("^\\s*%s\\s*=\\s*", field), "", rest[hit[1]])

  if (grepl("^\\[", val)) {
    # Authors are an array, possibly spanning lines.
    joined <- paste(rest[hit[1]:length(rest)], collapse = " ")
    val <- sub("^\\s*[a-z-]+\\s*=\\s*\\[", "", joined)
    val <- sub("\\].*$", "", val)
    parts <- regmatches(val, gregexpr('"[^"]*"', val))[[1]]
    return(paste(gsub('"', "", parts), collapse = ", "))
  }
  trimws(gsub('"', "", sub("#.*$", "", val)))
}

crates <- sort(list.dirs(vendor_dir, recursive = FALSE, full.names = TRUE))
entries <- vapply(crates, function(dir) {
  toml <- file.path(dir, "Cargo.toml")
  if (!file.exists(toml)) return("")
  lines <- readLines(toml, warn = FALSE)
  nm <- read_field(lines, "name")
  authors <- read_field(lines, "authors")
  lic <- read_field(lines, "license")
  if (is.na(lic) || !nzchar(lic)) {
    lic <- read_field(lines, "license-file")
    if (!is.na(lic) && nzchar(lic)) lic <- paste0("see ", lic)
  }
  repo <- read_field(lines, "repository")
  paste(
    "-------------------------------------------------------------",
    sprintf("Name:        %s", if (is.na(nm)) basename(dir) else nm),
    sprintf("Repository:  %s", if (is.na(repo)) "unknown" else repo),
    sprintf("Authors:     %s", if (is.na(authors) || !nzchar(authors)) "unstated" else authors),
    sprintf("License:     %s", if (is.na(lic) || !nzchar(lic)) "unstated" else lic),
    "",
    sep = "\n"
  )
}, character(1))

header <- c(
  "The binary compiled from the source code of this package statically links",
  "Apache Iceberg Rust and its dependency tree. The crates below are bundled in",
  "src/rust/vendor.tar.xz. See also the NOTICE file at the package root.",
  "",
  sprintf("Inventory generated by tools/vendor.R from %d vendored crates.", length(crates)),
  "",
  ""
)

writeLines(c(header, entries), "LICENSE.note")
message("Wrote LICENSE.note (", length(crates), " crates).")
