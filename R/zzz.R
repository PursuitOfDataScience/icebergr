# Conditional registration of the dplyr::collect() method.
#
# dplyr is not a dependency: it would be a heavy import for the sake of one
# generic. Instead the method is registered at load time if and when dplyr is
# present, so `collect(tbl)` works for tidyverse users while
# `icebergr_collect(tbl)` always works.

.onLoad <- function(libname, pkgname) {
  s3_register("dplyr::collect", "icebergr_scan", function(x, ...) icebergr_collect(x, ...))
  s3_register("dplyr::collect", "icebergr_table", function(x, ...) icebergr_collect(x, ...))
  invisible()
}

# The standard s3_register() helper distributed with vctrs and rlang (MIT
# licensed), which exists precisely so that a package can register methods for
# generics it does not depend on.
s3_register <- function(generic, class, method = NULL) {
  stopifnot(is.character(generic), length(generic) == 1L)
  stopifnot(is.character(class), length(class) == 1L)

  pieces <- strsplit(generic, "::")[[1L]]
  stopifnot(length(pieces) == 2L)
  package <- pieces[[1L]]
  generic <- pieces[[2L]]

  caller <- parent.frame()

  get_method_env <- function() {
    top <- topenv(caller)
    if (isNamespace(top)) asNamespace(environmentName(top)) else caller
  }

  get_method <- function(method) {
    if (is.null(method)) {
      get(paste0(generic, ".", class), envir = get_method_env())
    } else {
      method
    }
  }

  # Register now if the package is already loaded, and again on any later load,
  # since the generic's package may be attached after us.
  setHook(
    packageEvent(package, "onLoad"),
    function(...) {
      registerS3method(generic, class, get_method(method), envir = asNamespace(package))
    }
  )

  if (!isNamespaceLoaded(package)) {
    return(invisible())
  }

  registerS3method(generic, class, get_method(method), envir = asNamespace(package))
  invisible()
}
