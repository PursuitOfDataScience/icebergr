# Generate src/Makevars{,.win} from the .in templates.
#
# The substitutions decide four things:
#   * whether cargo may reach the network (it may not, when building for CRAN),
#   * whether we build release or debug,
#   * whether the target directory is cleaned afterwards,
#   * which optional Cargo features are compiled in.

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

# rustls-native-certs reads the macOS system trust store through the Security
# framework, and reqwest's proxy detection pulls in SystemConfiguration. Decided
# here rather than with `ifeq` in the template, so that the generated Makevars
# stays free of the GNU make extensions R CMD check warns about.
.pkg_libs_extra <- if (identical(Sys.info()[["sysname"]], "Darwin")) {
  "-framework Security -framework CoreFoundation -framework SystemConfiguration"
} else {
  ""
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

mv_txt <- readLines(mv_fp)

new_txt <- gsub("@CRAN_FLAGS@", .cran_flags, mv_txt)
new_txt <- gsub("@FEATURES@", .features, new_txt)
new_txt <- gsub("@PKG_LIBS_EXTRA@", .pkg_libs_extra, new_txt)
new_txt <- gsub("@PROFILE@", .profile, new_txt)
new_txt <- gsub("@CLEAN_TARGET@", .clean_targets, new_txt)
new_txt <- gsub("@LIBDIR@", .libdir, new_txt)

message("Writing `", mv_ofp, "`.")
con <- file(mv_ofp, open = "wb")
writeLines(new_txt, con, sep = "\n")
close(con)

message("`tools/config.R` has finished.")
