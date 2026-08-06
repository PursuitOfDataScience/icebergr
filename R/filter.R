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

#' @noRd
is_column_ref <- function(e, columns) {
  is.symbol(e) && as.character(e) %in% columns
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
translate_filter <- function(e, columns, env, call = rlang::caller_env()) {
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

  # Parentheses carry no meaning once we have the parse tree.
  if (fn == "(") {
    return(translate_filter(e[[2L]], columns, env, call))
  }

  if (fn %in% c("&", "&&")) {
    return(list(
      op = "and",
      args = list(
        translate_filter(e[[2L]], columns, env, call),
        translate_filter(e[[3L]], columns, env, call)
      )
    ))
  }

  if (fn %in% c("|", "||")) {
    return(list(
      op = "or",
      args = list(
        translate_filter(e[[2L]], columns, env, call),
        translate_filter(e[[3L]], columns, env, call)
      )
    ))
  }

  if (fn == "!") {
    inner <- e[[2L]]
    # !is.na(x) is common enough to deserve the direct is_not_null predicate
    # rather than a negated is_null.
    if (is.call(inner) && deparse1(inner[[1L]]) == "is.na" &&
      is_column_ref(inner[[2L]], columns)) {
      return(list(op = "is_not_null", col = as.character(inner[[2L]])))
    }
    if (is.call(inner) && deparse1(inner[[1L]]) == "is.nan" &&
      is_column_ref(inner[[2L]], columns)) {
      return(list(op = "is_not_nan", col = as.character(inner[[2L]])))
    }
    return(list(op = "not", arg = translate_filter(inner, columns, env, call)))
  }

  if (fn == "is.na") {
    if (!is_column_ref(e[[2L]], columns)) {
      unsupported_filter("is.na() must be applied to a column of the table", call)
    }
    return(list(op = "is_null", col = as.character(e[[2L]])))
  }

  if (fn == "is.nan") {
    if (!is_column_ref(e[[2L]], columns)) {
      unsupported_filter("is.nan() must be applied to a column of the table", call)
    }
    return(list(op = "is_nan", col = as.character(e[[2L]])))
  }

  if (fn == "startsWith") {
    if (!is_column_ref(e[[2L]], columns)) {
      unsupported_filter("startsWith() must be applied to a column of the table", call)
    }
    prefix <- eval_literal(e[[3L]], env, call)
    if (!is.character(prefix) || length(prefix) != 1L) {
      unsupported_filter("the prefix in startsWith() must be a single string", call)
    }
    return(list(op = "starts_with", col = as.character(e[[2L]]), value = prefix))
  }

  if (fn == "%in%") {
    if (!is_column_ref(e[[2L]], columns)) {
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
    return(list(op = "in", col = as.character(e[[2L]]), values = as.list(values)))
  }

  if (fn %in% names(comparison_ops)) {
    op <- comparison_ops[[fn]]
    lhs <- e[[2L]]
    rhs <- e[[3L]]

    if (is_column_ref(lhs, columns)) {
      column <- as.character(lhs)
      value <- eval_literal(rhs, env, call)
    } else if (is_column_ref(rhs, columns)) {
      column <- as.character(rhs)
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
  x <- gsub("\n", "\\n", x, fixed = TRUE)
  x <- gsub("\r", "\\r", x, fixed = TRUE)
  x <- gsub("\t", "\\t", x, fixed = TRUE)
  paste0('"', x, '"')
}

#' @noRd
json_scalar <- function(v, call = rlang::caller_env()) {
  if (length(v) != 1L) {
    abort("Internal error: expected a scalar filter value.", call = call)
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
