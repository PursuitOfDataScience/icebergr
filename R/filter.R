# Translating R filter expressions into Iceberg predicates.
#
# `filter = year == 2024 & amount > 100` is walked here and emitted as a small
# JSON tree, which the Rust side turns into an `iceberg::expr::Predicate`.
# iceberg-rust has no expression parser, so this translation is what makes
# predicate pushdown reachable from R at all.
#
# A symbol is treated as a column when it names one in the table schema, and
# otherwise evaluated in the calling environment. That is what lets
# `filter = year == target_year` work with a local `target_year`.

comparison_ops <- c(
  "==" = "eq", "!=" = "ne",
  "<" = "lt", "<=" = "lte",
  ">" = "gt", ">=" = "gte"
)

# Reversing the operands of an inequality reverses the operator.
flipped_ops <- c(lt = "gt", lte = "gte", gt = "lt", gte = "lte", eq = "eq", ne = "ne")

#' The table column a symbol names, or NULL
#'
#' Returns the column's spelling *as the table has it*, which is what makes
#' `case_sensitive = FALSE` work: `iceberg-rust` binds the snapshot-level
#' predicate case-sensitively regardless of the scan's own setting, so a
#' differently-cased name has to be resolved here rather than left to it.
#' @noRd
column_ref <- function(e, columns, case_sensitive = TRUE,
                       call = rlang::caller_env()) {
  if (!is.symbol(e)) {
    return(NULL)
  }
  hit <- column_index(as.character(e), columns, case_sensitive, call = call)
  if (is.na(hit)) NULL else columns[[hit]]
}

#' @noRd
unsupported_filter <- function(what, call) {
  abort(
    c(
      paste0("Cannot push this filter down to Iceberg: ", what, "."),
      i = paste(
        "Supported: ==, !=, <, <=, >, >=, &, |, !, %in%, is.na(), is.nan()",
        "and startsWith()."
      ),
      i = "Anything else can be applied in R after icebergr_collect()."
    ),
    class = "icebergr_unsupported_filter",
    call = call
  )
}

#' @noRd
eval_literal <- function(e, env, call) {
  value <- tryCatch(
    eval(e, envir = env),
    error = function(err) {
      abort(
        c(
          paste0(
            "Could not evaluate ", encodeString(deparse1(e), quote = "`"),
            " in the filter."
          ),
          x = conditionMessage(err),
          i = "A bare name is read as a column only if the table has a column of that name."
        ),
        call = call
      )
    }
  )
  value
}

#' @noRd
translate_filter <- function(e, columns, env, case_sensitive = TRUE,
                             call = rlang::caller_env()) {
  recurse <- function(x) translate_filter(x, columns, env, case_sensitive, call)
  as_column <- function(x) column_ref(x, columns, case_sensitive, call = call)

  # A literal TRUE/FALSE is a legitimate, if unusual, filter.
  if (is.logical(e) && length(e) == 1L && !is.na(e)) {
    return(list(op = if (e) "always_true" else "always_false"))
  }

  if (is.symbol(e)) {
    unsupported_filter(
      paste0(
        encodeString(as.character(e), quote = "`"),
        " is not a comparison. Iceberg has no boolean-column shorthand; write ",
        encodeString(paste0(as.character(e), " == TRUE"), quote = "`")
      ),
      call
    )
  }

  if (!is.call(e)) {
    unsupported_filter(paste0(encodeString(deparse1(e), quote = "`"), " is not an expression"), call)
  }

  fn <- deparse1(e[[1L]])

  # `is.na()` and `startsWith("a")` parse perfectly well, so the argument count
  # has to be checked before indexing into the call. Without this the report is
  # "subscript out of bounds", which says nothing about the filter.
  #
  # The binary operators are here too. They cannot be written short in infix
  # form, but the prefix spelling parses -- `` `>`(id) `` and `` `&`(id > 1) ``
  # are both valid calls -- and each reached an `e[[3L]]` that was not there.
  arity <- c(
    "(" = 2L, "!" = 2L, "is.na" = 2L, "is.nan" = 2L, "startsWith" = 3L,
    "&" = 3L, "&&" = 3L, "|" = 3L, "||" = 3L, "%in%" = 3L,
    "==" = 3L, "!=" = 3L, "<" = 3L, "<=" = 3L, ">" = 3L, ">=" = 3L
  )
  if (fn %in% names(arity) && length(e) != arity[[fn]]) {
    # Named by the function rather than by deparse1(e): R deparses an operator
    # call that is short of an operand by running the pieces together, so
    # `` `>`(id) `` comes out as ">id", which reads like a typo in the message
    # rather than a description of one in the filter.
    unsupported_filter(
      paste0(
        encodeString(fn, quote = "`"), " takes ", arity[[fn]] - 1L,
        " argument(s), not ", length(e) - 1L
      ),
      call
    )
  }

  # Parentheses carry no meaning once we have the parse tree.
  if (fn == "(") {
    return(recurse(e[[2L]]))
  }

  if (fn %in% c("&", "&&")) {
    return(list(op = "and", args = list(recurse(e[[2L]]), recurse(e[[3L]]))))
  }

  if (fn %in% c("|", "||")) {
    return(list(op = "or", args = list(recurse(e[[2L]]), recurse(e[[3L]]))))
  }

  if (fn == "!") {
    inner <- e[[2L]]
    # !is.na(x) is common enough to deserve the direct is_not_null predicate
    # rather than a negated is_null.
    if (is.call(inner) && length(inner) == 2L) {
      inner_fn <- deparse1(inner[[1L]])
      column <- as_column(inner[[2L]])
      if (!is.null(column) && inner_fn == "is.na") {
        return(list(op = "is_not_null", col = column))
      }
      if (!is.null(column) && inner_fn == "is.nan") {
        return(list(op = "is_not_nan", col = column))
      }
    }
    return(list(op = "not", arg = recurse(inner)))
  }

  if (fn == "is.na") {
    column <- as_column(e[[2L]])
    if (is.null(column)) {
      unsupported_filter("is.na() must be applied to a column of the table", call)
    }
    return(list(op = "is_null", col = column))
  }

  if (fn == "is.nan") {
    column <- as_column(e[[2L]])
    if (is.null(column)) {
      unsupported_filter("is.nan() must be applied to a column of the table", call)
    }
    return(list(op = "is_nan", col = column))
  }

  if (fn == "startsWith") {
    column <- as_column(e[[2L]])
    if (is.null(column)) {
      unsupported_filter("startsWith() must be applied to a column of the table", call)
    }
    prefix <- eval_literal(e[[3L]], env, call)
    if (!is.character(prefix) || length(prefix) != 1L) {
      unsupported_filter("the prefix in startsWith() must be a single string", call)
    }
    return(list(op = "starts_with", col = column, value = prefix))
  }

  if (fn == "%in%") {
    column <- as_column(e[[2L]])
    if (is.null(column)) {
      unsupported_filter("the left side of %in% must be a column of the table", call)
    }
    values <- eval_literal(e[[3L]], env, call)
    if (anyNA(values)) {
      abort(
        c(
          "`%in%` with NA cannot be pushed down.",
          i = "Iceberg set predicates have no NA member; combine with is.na() instead."
        ),
        call = call
      )
    }
    return(list(op = "in", col = column, values = as.list(values)))
  }

  if (fn %in% names(comparison_ops)) {
    op <- comparison_ops[[fn]]
    lhs <- e[[2L]]
    rhs <- e[[3L]]

    column <- as_column(lhs)
    if (!is.null(column)) {
      value <- eval_literal(rhs, env, call)
    } else if (!is.null(column <- as_column(rhs))) {
      value <- eval_literal(lhs, env, call)
      op <- flipped_ops[[op]]
    } else {
      unsupported_filter(
        paste0(
          "neither side of ", encodeString(deparse1(e), quote = "`"),
          " names a column of the table. Columns are: ",
          paste(columns, collapse = ", ")
        ),
        call
      )
    }

    if (length(value) != 1L) {
      unsupported_filter(
        paste0(
          "comparing ", encodeString(column, quote = "`"), " against ",
          length(value), " values; use %in% for a set"
        ),
        call
      )
    }
    return(list(op = op, col = column, value = value))
  }

  unsupported_filter(paste0(encodeString(fn, quote = "`"), " is not supported"), call)
}

# ---- minimal JSON writer -----------------------------------------------------
# The predicate tree is a small closed structure, so serialising it by hand is
# cheaper than taking a dependency on a JSON package.

#' @noRd
json_string <- function(x) {
  x <- enc2utf8(as.character(x))
  x <- gsub("\\", "\\\\", x, fixed = TRUE)
  x <- gsub('"', '\\"', x, fixed = TRUE)
  x <- gsub("\b", "\\b", x, fixed = TRUE)
  x <- gsub("\f", "\\f", x, fixed = TRUE)
  x <- gsub("\n", "\\n", x, fixed = TRUE)
  x <- gsub("\r", "\\r", x, fixed = TRUE)
  x <- gsub("\t", "\\t", x, fixed = TRUE)
  # JSON forbids any unescaped C0 control character, not just the five that have
  # a short form. A stray one would otherwise produce a document the Rust side
  # cannot parse, surfacing as an unhelpful "could not read the filter
  # expression". Matched literally rather than with [[:cntrl:]], which is
  # locale-dependent and also covers DEL and the C1 range, neither of which JSON
  # requires escaping.
  for (cp in setdiff(1:31, c(8L, 9L, 10L, 12L, 13L))) {
    ch <- intToUtf8(cp)
    # na.rm: grepl() is NA for an NA element, and `if (NA)` is an error. NA never
    # reaches here today -- json_scalar() rejects it first, and op and col are
    # never NA -- but this helper should not be the thing that breaks if it ever
    # does.
    if (any(grepl(ch, x, fixed = TRUE), na.rm = TRUE)) {
      x <- gsub(ch, sprintf("\\u%04x", cp), x, fixed = TRUE)
    }
  }
  paste0('"', x, '"')
}

#' @noRd
json_scalar <- function(v, call = rlang::caller_env()) {
  if (length(v) != 1L) {
    abort("Internal error: expected a scalar filter value.", call = call)
  }
  # NaN and Inf are only meaningful for a plain double. bit64::integer64 is also
  # a double underneath, and the int64 bit pattern of a large value can look like
  # NaN, so classed values must not be tested this way.
  bare_double <- is.double(v) && is.null(attr(v, "class"))
  if (bare_double && is.nan(v)) {
    abort(
      c(
        "A filter compared a column against NaN.",
        i = "Use is.nan(column) or !is.nan(column) to test for NaN."
      ),
      call = call
    )
  }
  if (is.na(v)) {
    abort(
      c(
        "A filter compared a column against NA.",
        i = "Use is.na(column) or !is.na(column) to test for nulls."
      ),
      call = call
    )
  }
  # JSON has no token for an infinity, so letting one through would emit a
  # document the Rust side cannot parse.
  if (bare_double && is.infinite(v)) {
    abort(
      c(
        "A filter compared a column against an infinite value.",
        i = "JSON has no representation for Inf, so it cannot be pushed down.",
        i = "Drop the bound, or apply it in R after icebergr_collect()."
      ),
      call = call
    )
  }

  if (inherits(v, "Date")) {
    return(json_string(format(v, "%Y-%m-%d")))
  }
  if (inherits(v, "POSIXt")) {
    # Normalised to UTC and marked with Z, so there is no ambiguity about which
    # zone the comparison happens in.
    return(json_string(format(as.POSIXct(v, tz = "UTC"), "%Y-%m-%dT%H:%M:%OS6Z", tz = "UTC")))
  }
  if (inherits(v, "integer64")) {
    # As a digit string: an int64 beyond 2^53 cannot survive as a JSON number.
    return(json_string(format(v, scientific = FALSE)))
  }
  if (is.factor(v)) {
    return(json_string(as.character(v)))
  }
  if (is.logical(v)) {
    return(if (v) "true" else "false")
  }
  if (is.character(v)) {
    return(json_string(v))
  }
  if (is.numeric(v)) {
    if (is.integer(v)) {
      return(format(v, scientific = FALSE))
    }
    if (v == trunc(v) && abs(v) <= 2^53) {
      return(format(v, scientific = FALSE, trim = TRUE))
    }
    return(format(v, digits = 17, scientific = FALSE, trim = TRUE))
  }

  abort(
    paste0("Filter values of class ", class(v)[[1L]], " are not supported."),
    call = call
  )
}

#' @noRd
filter_to_json <- function(node) {
  op <- node$op

  if (op %in% c("always_true", "always_false")) {
    return(paste0('{"op":', json_string(op), "}"))
  }

  if (op %in% c("and", "or")) {
    args <- vapply(node$args, filter_to_json, character(1))
    return(paste0('{"op":', json_string(op), ',"args":[', paste(args, collapse = ","), "]}"))
  }

  if (op == "not") {
    return(paste0('{"op":"not","arg":', filter_to_json(node$arg), "}"))
  }

  if (op %in% c("is_null", "is_not_null", "is_nan", "is_not_nan")) {
    return(paste0('{"op":', json_string(op), ',"col":', json_string(node$col), "}"))
  }

  if (op %in% c("in", "not_in")) {
    values <- vapply(node$values, json_scalar, character(1))
    return(paste0(
      '{"op":', json_string(op), ',"col":', json_string(node$col),
      ',"values":[', paste(values, collapse = ","), "]}"
    ))
  }

  paste0(
    '{"op":', json_string(op), ',"col":', json_string(node$col),
    ',"value":', json_scalar(node$value), "}"
  )
}
