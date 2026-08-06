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

/// Build a predicate from the JSON tree produced by the R translator.
pub fn build_predicate(json: &str, schema: &Schema, case_sensitive: bool) -> RResult<Predicate> {
    let node: Node =
        serde_json::from_str(json).map_err(|e| ctx("could not read the filter expression", e))?;
    build(&node, schema, case_sensitive)
}

fn build(node: &Node, schema: &Schema, ci: bool) -> RResult<Predicate> {
    // Iceberg's And/Or are strictly binary, so an n-ary R expression is folded.
    fn fold(
        args: &[Node],
        schema: &Schema,
        ci: bool,
        empty: Predicate,
        join: fn(Predicate, Predicate) -> Predicate,
    ) -> RResult<Predicate> {
        let mut it = args.iter();
        let Some(first) = it.next() else {
            return Ok(empty);
        };
        let mut acc = build(first, schema, ci)?;
        for n in it {
            acc = join(acc, build(n, schema, ci)?);
        }
        Ok(acc)
    }

    Ok(match node {
        Node::And { args } => fold(args, schema, ci, Predicate::AlwaysTrue, Predicate::and)?,
        Node::Or { args } => fold(args, schema, ci, Predicate::AlwaysFalse, Predicate::or)?,
        Node::Not { arg } => build(arg, schema, ci)?.negate(),
        Node::AlwaysTrue => Predicate::AlwaysTrue,
        Node::AlwaysFalse => Predicate::AlwaysFalse,

        Node::IsNull { col } => reference(col, schema, ci)?.0.is_null(),
        Node::IsNotNull { col } => reference(col, schema, ci)?.0.is_not_null(),
        Node::IsNan { col } => reference(col, schema, ci)?.0.is_nan(),
        Node::IsNotNan { col } => reference(col, schema, ci)?.0.is_not_nan(),

        Node::Eq { col, value } => binary(col, value, schema, ci, Reference::equal_to)?,
        Node::Ne { col, value } => binary(col, value, schema, ci, Reference::not_equal_to)?,
        Node::Lt { col, value } => binary(col, value, schema, ci, Reference::less_than)?,
        Node::Lte { col, value } => {
            binary(col, value, schema, ci, Reference::less_than_or_equal_to)?
        }
        Node::Gt { col, value } => binary(col, value, schema, ci, Reference::greater_than)?,
        Node::Gte { col, value } => {
            binary(col, value, schema, ci, Reference::greater_than_or_equal_to)?
        }
        Node::StartsWith { col, value } => binary(col, value, schema, ci, Reference::starts_with)?,
        Node::NotStartsWith { col, value } => {
            binary(col, value, schema, ci, Reference::not_starts_with)?
        }

        Node::In { col, values } => {
            let (r, ty) = reference(col, schema, ci)?;
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
            let (r, ty) = reference(col, schema, ci)?;
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
    ci: bool,
    f: fn(Reference, Datum) -> Predicate,
) -> RResult<Predicate> {
    let (r, ty) = reference(col, schema, ci)?;
    Ok(f(r, datum(value, &ty, col)?))
}

/// Resolve a column name to a reference plus the primitive type of its literals.
fn reference(col: &str, schema: &Schema, ci: bool) -> RResult<(Reference, PrimitiveType)> {
    let field = if ci {
        schema.field_by_name_case_insensitive(col)
    } else {
        schema.field_by_name(col)
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
        other => Err(RError::Other(format!(
            "cannot filter on {col:?}: it has type {other}, and filters are \
             supported only on primitive columns. Filter on a nested field by \
             its full path, or select it and filter in R instead."
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
                .map_err(|e| ctx("invalid timestamp", e))?,
            _ => Datum::timestamp_micros(as_i64()?),
        },
        PrimitiveType::Timestamptz => match value {
            Json::String(s) => {
                Datum::timestamptz_from_str(s).map_err(|e| ctx("invalid timestamp", e))?
            }
            _ => Datum::timestamptz_micros(as_i64()?),
        },
        PrimitiveType::TimestampNs => match value {
            Json::String(s) => Datum::timestamp_from_str(s.trim_end_matches('Z'))
                .or_else(|_| Datum::timestamp_from_str(s))
                .map_err(|e| ctx("invalid timestamp", e))?,
            _ => Datum::timestamp_nanos(as_i64()?),
        },
        PrimitiveType::TimestamptzNs => match value {
            Json::String(s) => {
                Datum::timestamptz_from_str(s).map_err(|e| ctx("invalid timestamp", e))?
            }
            _ => Datum::timestamptz_nanos(as_i64()?),
        },

        PrimitiveType::String => Datum::string(as_str()?),
        PrimitiveType::Uuid => {
            Datum::uuid_from_str(as_str()?).map_err(|e| ctx("invalid UUID", e))?
        }
        PrimitiveType::Decimal { .. } => {
            // Going through the decimal string avoids a binary-float detour that
            // would silently perturb the value.
            let s = match value {
                Json::String(s) => s.clone(),
                other => other.to_string(),
            };
            Datum::decimal_from_str(&s).map_err(|e| ctx("invalid decimal", e))?
        }

        PrimitiveType::Time | PrimitiveType::Binary | PrimitiveType::Fixed(_) => {
            return Err(RError::Other(format!(
                "filtering on column {col:?} (Iceberg type {ty}) is not supported \
                 in icebergr 0.1.0. Select the column and filter it in R instead."
            )));
        }
    })
}
