# Generate src/Makevars{,.win} from the .in templates.
#
# The substitutions decide three things:
#   * whether cargo may reach the network (it may not, when building for CRAN),
#   * whether we build release or debug,
#   * whether the target directory is cleaned afterwards.

source("tools/msrv.R")

env_debug <- Sys.getenv("DEBUG")
env_not_cran <- Sys.getenv("NOT_CRAN")

vendor_exists <- file.exists("src/rust/vendor.tar.xz")

is_not_cran <- env_not_cran != ""
is_debug <- env_debug != ""

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

# Only restrict cargo when we are building for CRAN *and* we actually have the
# vendored sources to build from. `-j 2` keeps us inside CRAN's limit on
# parallelism, which cargo would otherwise blow past by defaulting to the
# number of logical CPUs.
.cran_flags <- if (!is_not_cran && vendor_exists) "-j 2 --offline" else ""

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

mv_txt <- readLines(mv_fp)

new_txt <- gsub("@CRAN_FLAGS@", .cran_flags, mv_txt)
new_txt <- gsub("@PROFILE@", .profile, new_txt)
new_txt <- gsub("@CLEAN_TARGET@", .clean_targets, new_txt)
new_txt <- gsub("@LIBDIR@", .libdir, new_txt)

message("Writing `", mv_ofp, "`.")
con <- file(mv_ofp, open = "wb")
writeLines(new_txt, con, sep = "\n")
close(con)

message("`tools/config.R` has finished.")
