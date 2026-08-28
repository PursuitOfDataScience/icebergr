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
#
# Size is the hard part. `cargo vendor` writes every package in Cargo.lock, and
# a lockfile is a union over platforms and over optional features -- cargo
# resolves dependencies without looking at `cfg(target_os)` or at which features
# are on, so the vendor tree that comes out is far larger than anything a build
# reads. For this package that was 442 crates and 344 MB, which compressed to a
# 33 MB tarball; CRAN's guidance is 10 MB. Of those 442 crates only 270 are
# compiled on any platform R runs on, and the largest single crate in the tree
# (aws-lc-sys, 63 MB of BoringSSL) is reached only through the opt-in `glue`
# feature, which a CRAN build never turns on.
#
# So this script reduces the tree in five stages before compressing it. In the
# order they run -- which is cheapest first, and so very nearly the reverse of
# the order of their yield:
#
#   1. test corpora, examples, benchmarks, fuzz targets and CI configuration.
#   2. files cargo never reads: each crate's own Cargo.lock (only ours counts
#      inside a vendor tree) and the Cargo.toml.orig copy `cargo package`
#      leaves behind, plus changelogs.
#   3. `#[cfg(test)]` modules that live inside src/ and so escaped stage 1, and
#      the cargo-public-api snapshots a few crates ship for their own CI.
#   4. windows-sys ships generated bindings for the whole Win32 surface, one
#      module per cargo feature, and 219 of its 246 modules are behind features
#      nothing here enables. 17 MB -> 3 MB.
#   5. crates outside the compiled set, cut down to their manifest -- 222 MB of
#      the 274 MB this all removes. They cannot simply be deleted: cargo's
#      resolver is target- and feature-blind, so it insists on finding every
#      lockfile entry in the directory source, and an absent one is a hard "no
#      matching package named ..." error at `cargo build` time. A manifest, a
#      licence and an empty lib satisfy the resolver, and nothing else about
#      them is ever read because the build never selects them.
#
# Then xz, tuned: pb=0 suits text far better than the default preset does.
#
# Every stage is mechanical and derived from what cargo itself reports, and the
# result is checked with `cargo metadata --offline --locked` before the archive
# is written, so a stage that goes too far fails here rather than on CRAN's
# build farm.

vendor_dir <- file.path("src", "rust", "vendor")
archive <- file.path("src", "rust", "vendor.tar.xz")
manifest <- file.path("src", "rust", "Cargo.toml")

if (Sys.which("cargo") == "") {
  stop("`cargo` was not found on the PATH.")
}
if (Sys.which("tar") == "") {
  stop("`tar` was not found on the PATH.")
}
if (Sys.which("xz") == "") {
  stop("`xz` was not found on the PATH.")
}

# Any stale vendor directory has to go, or removed dependencies linger in the
# archive and the licence inventory.
if (dir.exists(vendor_dir)) {
  message("Removing stale ", vendor_dir)
  unlink(vendor_dir, recursive = TRUE)
}

features <- Sys.getenv("ICEBERGR_CARGO_FEATURES")
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

dir_bytes <- function(paths) {
  files <- unlist(lapply(paths, function(p) {
    if (dir.exists(p)) {
      list.files(p, recursive = TRUE, all.files = TRUE, full.names = TRUE)
    } else {
      p
    }
  }), use.names = FALSE)
  files <- files[!is.na(files) & !dir.exists(files)]
  sum(file.size(files), na.rm = TRUE)
}

report <- function(label, before, after) {
  message(sprintf(
    "  %-46s %7.1f MB -> %7.1f MB  (-%5.1f MB)",
    label, before / 1024^2, after / 1024^2, (before - after) / 1024^2
  ))
}

crate_dirs <- function() list.dirs(vendor_dir, recursive = FALSE, full.names = TRUE)

total_before <- dir_bytes(vendor_dir)
message(sprintf(
  "\nVendored %d crates, %.1f MB. Reducing to what a build reads.\n",
  length(crate_dirs()), total_before / 1024^2
))

# ---- which crates are actually compiled --------------------------------------
# The platforms R is built for. `cargo tree` filters by target, which is the
# only way to find out that (say) every windows_*_msvc import library and the
# whole wasm-bindgen subtree are dead weight here: cargo's own resolution keeps
# them because resolution ignores `cfg(...)` entirely.
#
# 32-bit Windows is deliberately absent -- R dropped it in 4.2, and DESCRIPTION
# requires R >= 4.2 -- and so is 32-bit x86 Linux, for the same practical
# reason CRAN no longer builds it.
targets <- c(
  "x86_64-unknown-linux-gnu",
  "aarch64-unknown-linux-gnu",
  "x86_64-apple-darwin",
  "aarch64-apple-darwin",
  "x86_64-pc-windows-gnu"
)

cargo_tree <- function(extra) {
  # system2() pastes its arguments into a shell command line, so anything with a
  # space in it -- the "{p} :: {f}" format below -- has to be quoted here or it
  # arrives at cargo as three separate arguments and the call fails.
  out <- suppressWarnings(system2(
    "cargo",
    shQuote(c(
      "tree", "--manifest-path", manifest, "--locked", "--edges", "normal,build",
      feature_args, extra
    )),
    stdout = TRUE, stderr = FALSE
  ))
  if (!is.null(attr(out, "status")) && attr(out, "status") != 0L) {
    stop("`cargo tree` failed; cannot determine which crates are compiled.")
  }
  out
}

root <- sub("^([^ ]+) v([^ ]+).*$", "\\1-\\2", cargo_tree(c("--prefix", "none", "--format", "{p}"))[1])

compiled <- unique(unlist(lapply(targets, function(target) {
  message("  resolving build graph for ", target)
  lines <- cargo_tree(c("--target", target, "--prefix", "none", "--format", "{p}"))
  lines <- lines[grepl("^[^ ]+ v[0-9]", lines)]
  sub("^([^ ]+) v([^ ]+).*$", "\\1-\\2", lines)
}), use.names = FALSE))
compiled <- setdiff(compiled, root)

vendored <- basename(crate_dirs())
missing <- setdiff(compiled, vendored)
if (length(missing)) {
  stop(
    "cargo reports crates that are not in the vendor tree: ",
    paste(missing, collapse = ", ")
  )
}
message(sprintf(
  "  %d of %d vendored crates are compiled on at least one of R's platforms.\n",
  length(compiled), length(vendored)
))

# ---- stages 1 and 2: test corpora, and files cargo never reads --------------
# Licence, notice and authorship files are never touched: they are required both
# by Apache-2.0 and by CRAN, and LICENSE.note below is generated from them.
licence_rx <- "^(LICEN[CS]E|COPYING|COPYRIGHT|NOTICE|AUTHORS|PATENTS)"

prunable <- c(
  "tests", "test", "examples", "example", "benches", "benchmarks", "fuzz",
  ".github", ".circleci", "ci", "testdata", "test_data", "test-data",
  "fixtures", "tests_data"
)
candidates <- list.files(
  vendor_dir,
  pattern = paste0("^(", paste(gsub("\\.", "\\\\.", prunable), collapse = "|"), ")$"),
  recursive = TRUE,
  include.dirs = TRUE,
  full.names = TRUE
)
candidates <- candidates[dir.exists(candidates)]
has_licence <- vapply(
  candidates,
  function(d) any(grepl(licence_rx, list.files(d, recursive = TRUE), ignore.case = TRUE)),
  logical(1)
)
before <- total_before
unlink(candidates[!has_licence], recursive = TRUE)
after <- dir_bytes(vendor_dir)
report(sprintf("test/example/CI directories (%d)", sum(!has_licence)), before, after)
if (any(has_licence)) {
  message(
    "    kept ", sum(has_licence),
    " otherwise-prunable directories because they contain licence files"
  )
}

# A crate's own Cargo.lock is meaningless inside a vendor tree (ours is the only
# one cargo reads) and Cargo.toml.orig is a copy `cargo package` leaves behind.
# Changelogs and READMEs are not read either -- except that a crate may pull its
# own README into rustdoc with include_str!, and then it really is a source
# file, so those are found and kept rather than guessed at.
before <- after
for (crate in crate_dirs()) {
  rs <- list.files(crate, pattern = "\\.rs$", recursive = TRUE, full.names = TRUE)
  referenced <- character()
  if (length(rs)) {
    text <- unlist(lapply(rs, readLines, warn = FALSE), use.names = FALSE)
    hits <- unlist(
      regmatches(text, gregexpr('include_(str|bytes)!\\s*\\(\\s*"[^"]+"', text)),
      use.names = FALSE
    )
    # The match still carries the macro name, so take what is between the
    # quotes -- not everything after the last one, which is the empty string.
    referenced <- basename(sub('^.*"([^"]+)"$', "\\1", hits))
  }
  droppable <- list.files(
    crate,
    pattern = "(\\.md$|^Cargo\\.lock$|^Cargo\\.toml\\.orig$)",
    recursive = TRUE, full.names = TRUE, ignore.case = TRUE
  )
  keep <- grepl(licence_rx, basename(droppable), ignore.case = TRUE) |
    basename(droppable) %in% referenced
  unlink(droppable[!keep])
}
after <- dir_bytes(vendor_dir)
report("changelogs, per-crate lockfiles, .orig copies", before, after)

# ---- stage 3: cfg(test) modules inside src/, and API snapshots ---------------
# Unit tests living inside src/ escaped the directory sweep above. A `tests`
# module is conventionally `#[cfg(test)]`, and then the file is dead weight in a
# non-test build -- but only conventionally, so the guard is read rather than
# assumed, and a module declared without it keeps its file. `public-api.txt` is a
# cargo-public-api snapshot that a few crates ship for their own CI.
before <- after
kept_tests <- 0L
for (crate in crate_dirs()) {
  units <- list.files(
    file.path(crate, "src"),
    pattern = "^tests?\\.rs$", recursive = TRUE, full.names = TRUE
  )
  for (unit in units) {
    modname <- sub("\\.rs$", "", basename(unit))
    declarers <- c(
      file.path(dirname(unit), c("mod.rs", "lib.rs")),
      paste0(dirname(unit), ".rs")
    )
    declarers <- declarers[file.exists(declarers)]
    gated <- any(vapply(declarers, function(f) {
      lines <- readLines(f, warn = FALSE)
      at <- grep(sprintf("^\\s*(pub\\s+)?mod\\s+%s\\s*;", modname), lines)[1]
      !is.na(at) && any(grepl("cfg\\(test\\)", lines[pmax(at - 2L, 1L):at]))
    }, logical(1)))
    if (gated) unlink(unit) else kept_tests <- kept_tests + 1L
  }
}
unlink(list.files(vendor_dir, pattern = "^public-api\\.txt$", recursive = TRUE, full.names = TRUE))
after <- dir_bytes(vendor_dir)
report("cfg(test) modules inside src/, API snapshots", before, after)
if (kept_tests) {
  message("    kept ", kept_tests, " test modules that are not cfg(test)-gated")
}

# ---- stage 4: windows-sys' unreachable half of the Win32 API -----------------
# Every module under src/Windows is `#[cfg(feature = "...")]`-gated, and the
# feature name is the module path with underscores for separators, so the
# feature set cargo resolves for the Windows target says exactly which files can
# go. Doing it from `cargo tree -f {f}` rather than from a hand-written list
# means a dependency that starts asking for a new part of the API is picked up
# automatically.
before <- after
for (crate in crate_dirs()) {
  name <- basename(crate)
  # A windows-sys the build never selects (an older major left in the lockfile
  # by some dependency) is not pruned here: stage 1 removes its sources whole.
  if (!grepl("^windows-sys-", name) || !name %in% compiled) next
  windows_root <- file.path(crate, "src", "Windows")
  if (!dir.exists(windows_root)) next

  lines <- cargo_tree(c(
    "--target", "x86_64-pc-windows-gnu", "--prefix", "none", "--format", "{p} :: {f}"
  ))
  spec <- sub("^([^ ]+) v([^ ]+)", "\\1-\\2", lines)
  spec <- spec[startsWith(spec, paste0(name, " "))]
  if (!length(spec)) {
    stop(name, " is vendored but absent from the Windows build graph.")
  }
  spec <- sub("\\s*\\(\\*\\)\\s*$", "", spec)
  enabled <- unique(unlist(strsplit(trimws(sub("^.*:: ", "", spec)), ","), use.names = FALSE))
  enabled <- setdiff(enabled, c("default", "docs", ""))

  keep <- c(
    file.path(windows_root, "mod.rs"),
    file.path(windows_root, gsub("_", "/", enabled), "mod.rs")
  )
  keep <- keep[file.exists(keep)]
  all_mods <- list.files(windows_root, pattern = "^mod\\.rs$", recursive = TRUE, full.names = TRUE)
  unlink(setdiff(all_mods, keep))
  # Directories left holding nothing are noise in the archive listing.
  repeat {
    empty <- list.dirs(windows_root, recursive = TRUE)
    empty <- empty[vapply(empty, function(d) {
      length(list.files(d, all.files = TRUE, no.. = TRUE)) == 0L
    }, logical(1))]
    if (!length(empty)) break
    unlink(empty, recursive = TRUE)
  }
  message(sprintf(
    "    %s: %d of %d API modules enabled", name, length(keep), length(all_mods)
  ))
}
after <- dir_bytes(vendor_dir)
report("windows-sys modules behind disabled features", before, after)

# ---- stage 5: crates no build compiles, reduced to their manifest ------------
# Cargo validates the *paths* a manifest declares when it parses it, even for a
# package it will never build, so an emptied crate still has to have a file
# wherever its manifest points. The vendored manifests are the normalised form
# cargo writes on publish, which always states `path` explicitly, so scraping
# those is enough; `build` is handled too, and gets a real empty main so that
# the file would compile if anything ever did reach for it.
before <- after
stubs <- setdiff(vendored, compiled)
for (name in stubs) {
  crate <- file.path(vendor_dir, name)
  toml <- file.path(crate, "Cargo.toml")
  lines <- readLines(toml, warn = FALSE)

  declared <- unlist(regmatches(
    lines, gregexpr('^\\s*(path|build)\\s*=\\s*"[^"]+"', lines)
  ), use.names = FALSE)
  declared <- gsub('^.*"([^"]+)"$', "\\1", declared)
  declared <- declared[!startsWith(declared, "..") & !startsWith(declared, "/")]
  declared <- unique(c("src/lib.rs", declared))

  survivors <- list.files(crate, all.files = TRUE, no.. = TRUE)
  protect <- survivors[
    survivors %in% c("Cargo.toml", ".cargo-checksum.json") |
      grepl(licence_rx, survivors, ignore.case = TRUE)
  ]
  unlink(file.path(crate, setdiff(survivors, protect)), recursive = TRUE)

  for (path in declared) {
    target <- file.path(crate, path)
    dir.create(dirname(target), recursive = TRUE, showWarnings = FALSE)
    body <- if (grepl("(^|/)(build|main)\\.rs$", path)) "fn main() {}" else character()
    writeLines(body, target)
  }
}
after <- dir_bytes(vendor_dir)
report(sprintf("crates reduced to a manifest (%d)", length(stubs)), before, after)

# ---- gate: no compiled crate lost a markdown file it includes ---------------
# A crate that pulls its own README into rustdoc with include_str! turns that
# file into a source file, and deleting it is a compile error rather than a
# resolution one -- so it survives `cargo metadata` and only surfaces minutes
# into an install. That is the one way the markdown sweep above can go wrong, so
# check it independently of the rule that did the sweeping.
#
# Matching on the basename anywhere in the crate rather than on the literal
# relative path is deliberate: `include_str!` inside a `macro_rules!` resolves
# against whichever file expands the macro, which is not knowable from here. The
# question that matters is whether the file is still in the archive at all.
# Files under src/bin are skipped -- those are [[bin]] targets, which cargo does
# not build for a library dependency.
missing_docs <- character()
for (name in compiled) {
  crate <- file.path(vendor_dir, name)
  present <- basename(list.files(crate, recursive = TRUE))
  sources <- list.files(crate, pattern = "\\.rs$", recursive = TRUE, full.names = TRUE)
  sources <- sources[!grepl("/src/bin/", sources, fixed = TRUE)]
  for (rs in sources) {
    text <- readLines(rs, warn = FALSE)
    hits <- unlist(
      regmatches(text, gregexpr('include_(str|bytes)!\\s*\\(\\s*"[^"]+\\.md"', text)),
      use.names = FALSE
    )
    if (!length(hits)) next
    wanted <- basename(sub('^.*"([^"]+)"$', "\\1", hits))
    gone <- setdiff(wanted, present)
    if (length(gone)) {
      missing_docs <- c(missing_docs, sprintf("%s needs %s", rs, paste(gone, collapse = ", ")))
    }
  }
}
if (length(missing_docs)) {
  stop(
    "pruning removed markdown that compiled crates include_str!:\n  ",
    paste(unique(missing_docs), collapse = "\n  ")
  )
}
message("\nNo compiled crate is missing a markdown file it includes.")

# ---- checksums --------------------------------------------------------------
# `cargo vendor` writes checksums that include the files we just pruned, so they
# have to be neutralised or cargo will refuse to build from the vendor tree.
checksums <- list.files(
  vendor_dir,
  pattern = "^\\.cargo-checksum\\.json$",
  recursive = TRUE,
  full.names = TRUE,
  all.files = TRUE
)
message("\nRewriting ", length(checksums), " vendored checksum files.")
for (f in checksums) {
  txt <- readLines(f, warn = FALSE)
  pkg <- sub('.*"package":\\s*("[a-f0-9]+"|null).*', "\\1", paste(txt, collapse = ""))
  if (identical(pkg, paste(txt, collapse = ""))) pkg <- "null"
  writeLines(sprintf('{"files":{},"package":%s}', pkg), f)
}

# ---- gate ------------------------------------------------------------------
# The whole point of the reductions above is that cargo never looks at what was
# removed. Prove it here, offline and against the pruned tree, rather than
# discovering otherwise on a build farm.
message("Checking that cargo still resolves the pruned tree offline.")
cargo_home <- file.path(tempdir(), "vendor-check-cargo-home")
dir.create(cargo_home, showWarnings = FALSE, recursive = TRUE)
# The shipped vendor-config.toml names the directory relatively, because at
# install time cargo runs from src/ with the tree unpacked beside it. Here it has
# to be absolute: a config read from CARGO_HOME resolves relative paths against
# CARGO_HOME, which is a temporary directory.
writeLines(
  c(
    '[source.crates-io]',
    'replace-with = "vendored-sources"',
    '',
    '[source.vendored-sources]',
    sprintf('directory = "%s"', normalizePath(vendor_dir))
  ),
  file.path(cargo_home, "config.toml")
)
gate_log <- tempfile(fileext = ".log")
status <- system2(
  "cargo",
  c(
    "metadata", "--manifest-path", manifest, "--offline", "--locked",
    "--format-version", "1"
  ),
  stdout = gate_log, stderr = gate_log,
  env = c(paste0("CARGO_HOME=", cargo_home), "CARGO_TERM_COLOR=never")
)
unlink(cargo_home, recursive = TRUE)
if (status != 0L) {
  detail <- readLines(gate_log, warn = FALSE)
  unlink(gate_log)
  stop(
    "the pruned vendor tree no longer resolves:\n",
    paste(utils::head(detail, 20L), collapse = "\n")
  )
}
unlink(gate_log)
message("  cargo metadata --offline --locked: OK")

# ---- archive ---------------------------------------------------------------
if (file.exists(archive)) invisible(file.remove(archive))

# pb=0 tells LZMA2 that matches are not aligned to a 4-byte boundary, which is
# true of text and worth ~1% here; the dictionary is sized to hold the whole
# tree in one window so that the four hundred near-identical licence files and
# the repeated generated code deduplicate against each other. Decompression
# needs the dictionary in memory, so it is capped at 128 MiB rather than raised
# to fit with room to spare.
message("Creating ", archive)
tarball <- tempfile(fileext = ".tar")
status <- system2(
  "tar",
  c("-cf", shQuote(tarball), "-C", shQuote(file.path("src", "rust")), "vendor")
)
if (status != 0L) {
  unlink(tarball)
  stop("`tar` failed with status ", status)
}
status <- system2(
  "xz",
  c(
    "--check=crc32", "--lzma2=preset=9e,dict=128MiB,pb=0", "--threads=1",
    "--stdout", shQuote(tarball)
  ),
  stdout = archive
)
unlink(tarball)
if (status != 0L) {
  stop("`xz` failed with status ", status)
}

size_mb <- file.size(archive) / 1024^2
message(sprintf(
  "\n%s: %.2f MB, from %d crates totalling %.1f MB on disk (was %.1f MB).",
  archive, size_mb, length(vendored), dir_bytes(vendor_dir) / 1024^2,
  total_before / 1024^2
))

# Where the weight actually is. A size exemption request is far easier to make
# with this list in hand than with a single total.
sizes <- vapply(crate_dirs(), dir_bytes, numeric(1))
top <- head(order(sizes, decreasing = TRUE), 15L)
message("\nLargest vendored crates (uncompressed):")
for (i in top) {
  message(sprintf("  %8.1f MB  %s", sizes[[i]] / 1024^2, basename(names(sizes)[[i]])))
}
message("")
if (size_mb > 10) {
  message(
    "NOTE: CRAN prefers source tarballs under 10 MB. At ", round(size_mb, 2),
    " MB the archive alone is over that, so the submission needs an\n",
    "explicit exemption request; see cran-comments.md and FEASIBILITY.md."
  )
}

# ---- LICENSE.note -----------------------------------------------------------
# Read each vendored crate's own manifest for authors, repository and licence.
# Doing it from the vendor tree rather than from `cargo metadata` means the
# inventory always describes exactly what is shipped -- including the crates
# that are present only as a manifest, which are still distributed and so still
# have to be credited.

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

crates <- sort(crate_dirs())
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
    sprintf("Compiled:    %s", if (basename(dir) %in% compiled) "yes" else "no, manifest only"),
    "",
    sep = "\n"
  )
}, character(1))

header <- c(
  "The binary compiled from the source code of this package statically links",
  "Apache Iceberg Rust and its dependency tree. The crates below are bundled in",
  "src/rust/vendor.tar.xz. See also inst/NOTICE.",
  "",
  sprintf("Inventory generated by tools/vendor.R from %d vendored crates.", length(crates)),
  sprintf(
  "%d of them are compiled into the library on at least one platform R runs on;",
    length(compiled)
  ),
  "the rest are entries in Cargo.lock that cargo's resolver insists on being",
  "able to find but that no build on any such platform reads, and are present",
  "as their manifest and licence only.",
  "",
  ""
)

writeLines(c(header, entries), "LICENSE.note")
message("Wrote LICENSE.note (", length(crates), " crates).")
