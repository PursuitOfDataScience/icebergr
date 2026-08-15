//! Translating R filter expressions into Iceberg predicates.
//!
//! iceberg-rust has no expression parser -- predicates are built
//! programmatically -- so the R side walks the quoted filter expression and
//! emits a small JSON tree, which is reassembled here into a `Predicate`.
//!
//! Literals are typed from the *column's* declared Iceberg type rather than
//! guessed from the JSON value. That is what makes `x > 5` work against a
//! `long` column and `d > "2024-01-01"` work against a `date` column, and it
//! turns a type error into a clear message here instead of an obscure failure
//! during scan planning.

use chrono::{DateTime, NaiveDateTime, Utc};
use extendr_api::Error as RError;
use iceberg::expr::{Predicate, Reference};
use iceberg::spec::{Datum, PrimitiveType, Schema, Type};
use serde::Deserialize;
use serde_json::Value as Json;

use crate::errors::{RResult, ctx};

#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
enum Node {
    And {
        args: Vec<Node>,
    },
    Or {
        args: Vec<Node>,
    },
    Not {
        arg: Box<Node>,
    },
    #[serde(rename = "always_true")]
    AlwaysTrue,
    #[serde(rename = "always_false")]
    AlwaysFalse,
    Eq {
        col: String,
        value: Json,
    },
    Ne {
        col: String,
        value: Json,
    },
    Lt {
        col: String,
        value: Json,
    },
    Lte {
        col: String,
        value: Json,
    },
    Gt {
        col: String,
        value: Json,
    },
    Gte {
        col: String,
        value: Json,
    },
    StartsWith {
        col: String,
        value: Json,
    },
    NotStartsWith {
        col: String,
        value: Json,
    },
    IsNull {
        col: String,
    },
    IsNotNull {
        col: String,
    },
    IsNan {
        col: String,
    },
    IsNotNan {
        col: String,
    },
    In {
        col: String,
        values: Vec<Json>,
    },
    NotIn {
        col: String,
        values: Vec<Json>,
    },
}

/// A predicate, plus what the scan needs to know about how to apply it.
pub struct BuiltPredicate {
    pub predicate: Predicate,
    /// Whether any column the predicate references is a `decimal`.
    ///
    /// iceberg-rust 0.10.0's row-selection filter drops *every* row for an
    /// ordering comparison against a decimal column. On a `decimal(10, 2)`
    /// holding 1.50, 2.25, 10.00 and 99.99, `price > 2.25` returns nothing and
    /// `price <= 10` returns nothing, while the same scans with row selection
    /// disabled return the two and three rows they should. Equality is
    /// unaffected, which is what makes it so easy to miss.
    ///
    /// Established by toggling row-group filtering and row selection
    /// independently, over every primitive type this package can write: only row
    /// selection changes the answer, and only for `decimal`. So the scan turns
    /// row selection off when this is set. Manifest, file and row-group pruning
    /// all still apply, so what it costs is the last and narrowest pruning stage
    /// on decimal filters only -- against silently returning no rows at all,
    /// which is the worst way for a filter to be wrong.
    pub has_decimal: bool,
}

/// Build a predicate from the JSON tree produced by the R translator.
pub fn build_predicate(
    json: &str,
    schema: &Schema,
    case_sensitive: bool,
) -> RResult<BuiltPredicate> {
    let node: Node =
        serde_json::from_str(json).map_err(|e| ctx("could not read the filter expression", e))?;
    let predicate = build(&node, schema, case_sensitive)?;

    let mut cols = Vec::new();
    referenced_columns(&node, &mut cols);
    // Every one of these resolved while `build` ran, so a failed lookup here is
    // not reachable; treating it as "not a decimal" keeps this from inventing a
    // second place that can reject a filter.
    let has_decimal = cols.iter().any(|c| {
        matches!(
            reference(c, schema, case_sensitive),
            Ok((_, PrimitiveType::Decimal { .. }))
        )
    });

    Ok(BuiltPredicate {
        predicate,
        has_decimal,
    })
}

/// Every column the predicate refers to.
fn referenced_columns<'a>(node: &'a Node, out: &mut Vec<&'a str>) {
    match node {
        Node::And { args } | Node::Or { args } => {
            for n in args {
                referenced_columns(n, out);
            }
        }
        Node::Not { arg } => referenced_columns(arg, out),
        Node::AlwaysTrue | Node::AlwaysFalse => {}
        Node::Eq { col, .. }
        | Node::Ne { col, .. }
        | Node::Lt { col, .. }
        | Node::Lte { col, .. }
        | Node::Gt { col, .. }
        | Node::Gte { col, .. }
        | Node::StartsWith { col, .. }
        | Node::NotStartsWith { col, .. }
        | Node::IsNull { col }
        | Node::IsNotNull { col }
        | Node::IsNan { col }
        | Node::IsNotNan { col }
        | Node::In { col, .. }
        | Node::NotIn { col, .. } => out.push(col.as_str()),
    }
}

fn build(node: &Node, schema: &Schema, cs: bool) -> RResult<Predicate> {
    // Iceberg's And/Or are strictly binary, so an n-ary R expression is folded.
    fn fold(
        args: &[Node],
        schema: &Schema,
        cs: bool,
        empty: Predicate,
        join: fn(Predicate, Predicate) -> Predicate,
    ) -> RResult<Predicate> {
        let mut it = args.iter();
        let Some(first) = it.next() else {
            return Ok(empty);
        };
        let mut acc = build(first, schema, cs)?;
        for n in it {
            acc = join(acc, build(n, schema, cs)?);
        }
        Ok(acc)
    }

    Ok(match node {
        Node::And { args } => fold(args, schema, cs, Predicate::AlwaysTrue, Predicate::and)?,
        Node::Or { args } => fold(args, schema, cs, Predicate::AlwaysFalse, Predicate::or)?,
        Node::Not { arg } => build(arg, schema, cs)?.negate(),
        Node::AlwaysTrue => Predicate::AlwaysTrue,
        Node::AlwaysFalse => Predicate::AlwaysFalse,

        Node::IsNull { col } => reference(col, schema, cs)?.0.is_null(),
        Node::IsNotNull { col } => reference(col, schema, cs)?.0.is_not_null(),
        Node::IsNan { col } => reference(col, schema, cs)?.0.is_nan(),
        Node::IsNotNan { col } => reference(col, schema, cs)?.0.is_not_nan(),

        Node::Eq { col, value } => binary(col, value, schema, cs, Reference::equal_to)?,
        Node::Ne { col, value } => binary(col, value, schema, cs, Reference::not_equal_to)?,
        Node::Lt { col, value } => binary(col, value, schema, cs, Reference::less_than)?,
        Node::Lte { col, value } => {
            binary(col, value, schema, cs, Reference::less_than_or_equal_to)?
        }
        Node::Gt { col, value } => binary(col, value, schema, cs, Reference::greater_than)?,
        Node::Gte { col, value } => {
            binary(col, value, schema, cs, Reference::greater_than_or_equal_to)?
        }
        Node::StartsWith { col, value } => prefix(col, value, schema, cs, Reference::starts_with)?,
        Node::NotStartsWith { col, value } => {
            prefix(col, value, schema, cs, Reference::not_starts_with)?
        }

        Node::In { col, values } => {
            let (r, ty) = reference(col, schema, cs)?;
            let datums = values
                .iter()
                .map(|v| datum(v, &ty, col))
                .collect::<RResult<Vec<_>>>()?;
            // An empty set can never match. Say so directly rather than letting
            // an empty IN list turn into a scan of everything.
            if datums.is_empty() {
                Predicate::AlwaysFalse
            } else {
                r.is_in(datums)
            }
        }
        Node::NotIn { col, values } => {
            let (r, ty) = reference(col, schema, cs)?;
            let datums = values
                .iter()
                .map(|v| datum(v, &ty, col))
                .collect::<RResult<Vec<_>>>()?;
            if datums.is_empty() {
                Predicate::AlwaysTrue
            } else {
                r.is_not_in(datums)
            }
        }
    })
}

fn binary(
    col: &str,
    value: &Json,
    schema: &Schema,
    cs: bool,
    f: fn(Reference, Datum) -> Predicate,
) -> RResult<Predicate> {
    let (r, ty) = reference(col, schema, cs)?;
    Ok(f(r, datum(value, &ty, col)?))
}

/// A prefix comparison, which Iceberg defines only over string columns.
///
/// `startsWith(id, "1")` against an `int` column parses cleanly on both sides --
/// R sees a column and a single string, and the prefix `"1"` converts to the
/// integer `1` here -- so without this check the scan is planned against the
/// nonsense predicate `id STARTS WITH 1`. iceberg-rust does reject that, but only
/// from inside the statistics evaluators, and only for files that carry bounds:
/// a data file written without them would be read and its rows returned as
/// though the filter had been applied. The column and the operator are both in
/// hand here, so say so here instead.
fn prefix(
    col: &str,
    value: &Json,
    schema: &Schema,
    cs: bool,
    f: fn(Reference, Datum) -> Predicate,
) -> RResult<Predicate> {
    let (r, ty) = reference(col, schema, cs)?;
    if !matches!(ty, PrimitiveType::String) {
        return Err(RError::Other(format!(
            "cannot use startsWith() on column {col:?}: it has Iceberg type \
             {ty}, and Iceberg compares prefixes only on string columns.\n\
             Select the column and filter it in R after icebergr_collect() \
             instead."
        )));
    }
    Ok(f(r, datum(value, &ty, col)?))
}

/// Resolve a column name to a reference plus the primitive type of its literals.
fn reference(col: &str, schema: &Schema, cs: bool) -> RResult<(Reference, PrimitiveType)> {
    // `cs` is case *sensitivity*, matching icebergr_scan(case_sensitive =).
    // Getting this the wrong way round silently resolves "ID" to a column named
    // "id" on a case-sensitive scan, and refuses it on a case-insensitive one.
    let field = if cs {
        schema.field_by_name(col)
    } else {
        // An exact match first, even here. Iceberg column names are
        // case-sensitive, so a schema may hold both `id` and `ID`, and
        // iceberg-rust's case-insensitive index is a map keyed on the lowercased
        // name -- one of the two wins arbitrarily. Relaxing the match must not
        // resolve a name that *is* one of them to the other. R refuses a name
        // that matches two columns and no column exactly before it reaches here.
        schema
            .field_by_name(col)
            .or_else(|| schema.field_by_name_case_insensitive(col))
    };

    let Some(field) = field else {
        // Column names are not secrets, so listing them is the most helpful
        // thing we can do here.
        let mut names: Vec<&str> = schema
            .as_struct()
            .fields()
            .iter()
            .map(|f| f.name.as_str())
            .collect();
        names.sort_unstable();
        return Err(RError::Other(format!(
            "cannot filter on {col:?}: no such column in the table schema.\n\
             Available columns: {}",
            names.join(", ")
        )));
    };

    match field.field_type.as_ref() {
        Type::Primitive(p) => Ok((Reference::new(field.name.clone()), p.clone())),
        // No advice to filter on a nested field by its dotted path: it cannot
        // work by any route. iceberg-rust resolves such a path when *binding*
        // the predicate, because the schema's name index covers nested fields,
        // but then fails to plan the scan with "Field lat not found in schema";
        // and projecting one is refused outright as "not a direct child of
        // schema". Reading the parent column and filtering in R is the only
        // thing that does work, so that is what this says.
        other => Err(RError::Other(format!(
            "cannot filter on {col:?}: it has type {}, and Iceberg pushes down \
             filters only on primitive columns.\n\
             Nested fields cannot be pushed down at all, by their dotted path or \
             otherwise. Select {col:?} and filter it in R after \
             icebergr_collect().",
            crate::table::type_label(other)
        ))),
    }
}

/// Build a literal of the column's own type from an R-supplied JSON value.
fn datum(value: &Json, ty: &PrimitiveType, col: &str) -> RResult<Datum> {
    let mismatch = |wanted: &str| -> RError {
        RError::Other(format!(
            "cannot compare column {col:?} (Iceberg type {ty}) against the value \
             supplied: expected {wanted}."
        ))
    };

    // NA is deliberately rejected. `x == NA` is almost always a mistake, and
    // Iceberg has no three-valued comparison to express it; is.na(x) maps to
    // is_null instead.
    if value.is_null() {
        return Err(RError::Other(format!(
            "cannot compare column {col:?} against NA. Use is.na({col}) or \
             !is.na({col}) to test for nulls."
        )));
    }

    let as_i64 = || -> RResult<i64> {
        value
            .as_i64()
            // bit64::integer64 arrives as a digit string, because an int64 past
            // 2^53 cannot survive as a JSON number.
            .or_else(|| value.as_str().and_then(|s| s.trim().parse::<i64>().ok()))
            .or_else(|| {
                value
                    .as_f64()
                    .filter(|f| f.fract() == 0.0)
                    .map(|f| f as i64)
            })
            .ok_or_else(|| mismatch("a whole number"))
    };
    let as_f64 = || -> RResult<f64> { value.as_f64().ok_or_else(|| mismatch("a number")) };
    let as_str = || -> RResult<&str> { value.as_str().ok_or_else(|| mismatch("a string")) };

    Ok(match ty {
        PrimitiveType::Boolean => {
            Datum::bool(value.as_bool().ok_or_else(|| mismatch("TRUE or FALSE"))?)
        }
        PrimitiveType::Int => {
            let v = as_i64()?;
            let v = i32::try_from(v).map_err(|_| {
                RError::Other(format!(
                    "value {v} is out of range for the 32-bit integer column {col:?}."
                ))
            })?;
            Datum::int(v)
        }
        PrimitiveType::Long => Datum::long(as_i64()?),
        PrimitiveType::Float => Datum::float(as_f64()? as f32),
        PrimitiveType::Double => Datum::double(as_f64()?),

        // Dates and timestamps arrive as ISO-8601 strings from R, which keeps
        // the conversion unambiguous. Numbers are accepted as the raw Iceberg
        // representation for callers who already have them.
        PrimitiveType::Date => match value {
            Json::String(s) => Datum::date_from_str(s).map_err(|e| ctx("invalid date", e))?,
            _ => Datum::date(i32::try_from(as_i64()?).map_err(|_| mismatch("a date"))?),
        },
        // R has no zone-less datetime, so a POSIXct compared against a
        // timestamp-without-timezone column arrives normalised to UTC and marked
        // with a trailing Z. Strip it rather than reject the comparison.
        PrimitiveType::Timestamp => match value {
            Json::String(s) => Datum::timestamp_from_str(s.trim_end_matches('Z'))
                .or_else(|_| Datum::timestamp_from_str(s))
                .map_err(|e| bad_timestamp(s, col, ty, e))?,
            _ => Datum::timestamp_micros(as_i64()?),
        },
        PrimitiveType::Timestamptz => match value {
            Json::String(s) => {
                Datum::timestamptz_from_str(s).map_err(|e| bad_timestamp(s, col, ty, e))?
            }
            _ => Datum::timestamptz_micros(as_i64()?),
        },
        // Nanosecond columns need a nanosecond literal. Datum::timestamp_from_str
        // builds a *microsecond* one, and iceberg-rust's Datum::to() explicitly
        // declines to convert between the two resolutions, so a micros literal
        // compared against ns file statistics would prune the wrong files. Parse
        // the ISO-8601 string here instead and scale it ourselves.
        PrimitiveType::TimestampNs => match value {
            Json::String(s) => Datum::timestamp_nanos(naive_nanos(s, col, ty)?),
            _ => Datum::timestamp_nanos(as_i64()?),
        },
        PrimitiveType::TimestamptzNs => match value {
            Json::String(s) => Datum::timestamptz_nanos(utc_nanos(s, col, ty)?),
            _ => Datum::timestamptz_nanos(as_i64()?),
        },

        PrimitiveType::String => Datum::string(as_str()?),
        PrimitiveType::Uuid => {
            Datum::uuid_from_str(as_str()?).map_err(|e| ctx("invalid UUID", e))?
        }
        PrimitiveType::Decimal { scale, .. } => {
            // Going through the decimal string avoids a binary-float detour that
            // would silently perturb the value.
            let s = match value {
                Json::String(s) => s.clone(),
                other => other.to_string(),
            };
            // Datum::decimal_from_str types the literal by however many decimal
            // places the string happens to carry, so "1.5" against a
            // decimal(10,2) column yields decimal(38,1). Iceberg compares
            // mantissas, so a scale that differs from the column's compares the
            // wrong number outright -- 15 against 150. Pad or trim the string to
            // the column's own scale first, then narrow the type to the column's
            // exact precision and scale.
            let rescaled = rescale_decimal(&s, *scale, col, ty)?;
            let datum =
                Datum::decimal_from_str(&rescaled).map_err(|e| ctx("invalid decimal", e))?;
            datum
                .to(&Type::Primitive(ty.clone()))
                .map_err(|e| ctx("invalid decimal", e))?
        }

        PrimitiveType::Time | PrimitiveType::Binary | PrimitiveType::Fixed(_) => {
            return Err(RError::Other(format!(
                "filtering on column {col:?} (Iceberg type {ty}) is not supported \
                 in icebergr 0.1.0. Select the column and filter it in R instead."
            )));
        }
    })
}

/// Report a timestamp literal that would not parse.
///
/// Comparing a timestamp column against a `Date` is a natural thing for an R
/// user to write and an unhelpful thing to be told about: the literal reaches
/// iceberg-rust as "2024-06-01" and comes back as "Can't parse datetime., source:
/// premature end of input", which describes its parser rather than the mistake.
/// Widening the date to midnight is not the answer either -- which midnight, and
/// in `==` a whole day is almost certainly what was meant rather than one instant
/// -- so name the problem and the fix and let the caller choose.
fn bad_timestamp<E: std::fmt::Display>(s: &str, col: &str, ty: &PrimitiveType, e: E) -> RError {
    let b = s.as_bytes();
    let looks_like_a_date = b.len() == 10
        && b[4] == b'-'
        && b[7] == b'-'
        && b.iter().enumerate().all(|(i, c)| {
            if i == 4 || i == 7 {
                true
            } else {
                c.is_ascii_digit()
            }
        });

    if looks_like_a_date {
        return RError::Other(format!(
            "cannot compare column {col:?} (Iceberg type {ty}) against the date \
             {s:?}: Iceberg does not widen a date to a timestamp, so the \
             comparison has no unambiguous meaning.\nGive the instant instead, \
             e.g. as.POSIXct(\"{s} 00:00:00\", tz = \"UTC\")."
        ));
    }
    ctx("invalid timestamp", e)
}

fn out_of_ns_range(s: &str, col: &str, ty: &PrimitiveType) -> RError {
    RError::Other(format!(
        "cannot compare column {col:?} (Iceberg type {ty}) against {s:?}: a \
         nanosecond timestamp only spans 1677-09-21 to 2262-04-11."
    ))
}

/// Nanoseconds since the epoch, for a zone-less ISO-8601 timestamp.
fn naive_nanos(s: &str, col: &str, ty: &PrimitiveType) -> RResult<i64> {
    // R has no zone-less datetime, so a POSIXct compared against a
    // timestamp-without-timezone column arrives normalised to UTC and marked
    // with a trailing Z. Drop the marker rather than reject the comparison.
    let dt = s
        .trim_end_matches('Z')
        .parse::<NaiveDateTime>()
        .or_else(|_| s.parse::<NaiveDateTime>())
        .map_err(|e| bad_timestamp(s, col, ty, e))?;
    dt.and_utc()
        .timestamp_nanos_opt()
        .ok_or_else(|| out_of_ns_range(s, col, ty))
}

/// Nanoseconds since the epoch, for an RFC-3339 timestamp with a zone.
fn utc_nanos(s: &str, col: &str, ty: &PrimitiveType) -> RResult<i64> {
    let dt = s
        .parse::<DateTime<Utc>>()
        .map_err(|e| bad_timestamp(s, col, ty, e))?;
    dt.timestamp_nanos_opt()
        .ok_or_else(|| out_of_ns_range(s, col, ty))
}

/// Rewrite a decimal string so that it carries exactly `scale` decimal places.
///
/// Iceberg stores a decimal as an unscaled mantissa plus a scale, and compares
/// mantissas. A literal whose scale differs from the column's is therefore not
/// merely imprecise, it is a different number: 1.5 at scale 1 is the mantissa
/// 15, while the column at scale 2 holds 150.
fn rescale_decimal(s: &str, scale: u32, col: &str, ty: &PrimitiveType) -> RResult<String> {
    let s = s.trim();
    let reject = |why: &str| -> RError {
        RError::Other(format!(
            "cannot compare column {col:?} (Iceberg type {ty}) against {s:?}: {why}"
        ))
    };

    if s.contains(['e', 'E']) {
        return Err(reject(
            "exponent notation cannot be read as a decimal. Write the value out in full.",
        ));
    }

    let (sign, rest) = match s.strip_prefix('-') {
        Some(rest) => ("-", rest),
        None => ("", s.strip_prefix('+').unwrap_or(s)),
    };
    let (int_part, frac_part) = rest.split_once('.').unwrap_or((rest, ""));

    let digits_only = |p: &str| p.bytes().all(|b| b.is_ascii_digit());
    if (int_part.is_empty() && frac_part.is_empty())
        || !digits_only(int_part)
        || !digits_only(frac_part)
    {
        return Err(reject("it is not a decimal number."));
    }

    let int_part = if int_part.is_empty() { "0" } else { int_part };
    let scale = scale as usize;

    let frac = if frac_part.len() > scale {
        let (keep, dropped) = frac_part.split_at(scale);
        // Trailing zeros are not information, so trimming them is lossless.
        if dropped.bytes().any(|b| b != b'0') {
            return Err(reject(&format!(
                "it has {} decimal places but the column has scale {scale}. Round \
                 the value first, or filter in R after collecting.",
                frac_part.len()
            )));
        }
        keep.to_string()
    } else {
        format!("{frac_part}{}", "0".repeat(scale - frac_part.len()))
    };

    if frac.is_empty() {
        Ok(format!("{sign}{int_part}"))
    } else {
        Ok(format!("{sign}{int_part}.{frac}"))
    }
}
