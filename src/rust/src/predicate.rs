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
use iceberg::spec::{Datum, PrimitiveLiteral, PrimitiveType, Schema, Type};
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
    let predicate = build(&node, schema, case_sensitive)?.t;

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

/// The rows where an R filter expression is TRUE, and the rows where it is FALSE.
///
/// R's logic has three values, and a filter keeps only the rows where the
/// expression is TRUE. Iceberg evaluates predicates with three values too (a
/// comparison with a null is null), but its values do not line up with R's:
///
/// * R's `%in%` is never NA. `NA %in% c(1, 2)` is FALSE, so `!(x %in% c(1, 2))`
///   keeps the rows where `x` is NA; Iceberg's `NOT IN` of a null is null, and
///   dropped them.
/// * A comparison with NaN is NA in R. The Arrow kernels iceberg-rust evaluates
///   rows with order floats totally, NaN above every number, so `x > 1` matched
///   NaN rows, and only in the files the scan read: file statistics leave NaN
///   out of their bounds, so a NaN in a file pruned for `x > 1` was not returned
///   while an identical one in a file that was read was. And `is.na()` is TRUE
///   for NaN in R, where Iceberg's `IS NULL` is not.
/// * The same total order puts -0.0 below 0.0, so `x == 0` missed a stored
///   -0.0, which R counts as zero.
///
/// So every node is built as the pair of predicates matching exactly the rows
/// where R says TRUE and exactly those where R says FALSE, and the connectives
/// combine the pairs as R does: `!` swaps them, `a & b` is TRUE where both are
/// TRUE and FALSE where either is FALSE, and `|` is the reverse. The scan uses
/// the TRUE half. Negation is resolved here and never handed to Iceberg, which
/// is what keeps Iceberg's own rules about nulls out of it.
struct Truth {
    t: Predicate,
    f: Predicate,
}

impl Truth {
    fn new(t: Predicate, f: Predicate) -> Self {
        Self { t, f }
    }

    fn not(self) -> Self {
        Self {
            t: self.f,
            f: self.t,
        }
    }
}

fn build(node: &Node, schema: &Schema, cs: bool) -> RResult<Truth> {
    Ok(match node {
        // Iceberg's And/Or are strictly binary, so an n-ary one is folded.
        // Predicate::and and ::or drop an AlwaysTrue or AlwaysFalse operand, so
        // the seeds add nothing to the result.
        Node::And { args } => {
            let (mut t, mut f) = (Predicate::AlwaysTrue, Predicate::AlwaysFalse);
            for n in args {
                let part = build(n, schema, cs)?;
                t = t.and(part.t);
                f = f.or(part.f);
            }
            Truth::new(t, f)
        }
        Node::Or { args } => {
            let (mut t, mut f) = (Predicate::AlwaysFalse, Predicate::AlwaysTrue);
            for n in args {
                let part = build(n, schema, cs)?;
                t = t.or(part.t);
                f = f.and(part.f);
            }
            Truth::new(t, f)
        }
        Node::Not { arg } => build(arg, schema, cs)?.not(),
        Node::AlwaysTrue => Truth::new(Predicate::AlwaysTrue, Predicate::AlwaysFalse),
        Node::AlwaysFalse => Truth::new(Predicate::AlwaysFalse, Predicate::AlwaysTrue),

        Node::IsNull { col } => missing(col, schema, cs)?,
        Node::IsNotNull { col } => missing(col, schema, cs)?.not(),
        // is.nan(NA) is FALSE, and Iceberg's NOT NAN is true of a null, so the
        // pair needs nothing added.
        Node::IsNan { col } => {
            let (r, _) = reference(col, schema, cs)?;
            Truth::new(r.clone().is_nan(), r.is_not_nan())
        }
        Node::IsNotNan { col } => build(&Node::IsNan { col: col.clone() }, schema, cs)?.not(),

        Node::Eq { col, value } => compare(Cmp::Eq, col, value, schema, cs)?,
        Node::Ne { col, value } => compare(Cmp::Ne, col, value, schema, cs)?,
        Node::Lt { col, value } => compare(Cmp::Lt, col, value, schema, cs)?,
        Node::Lte { col, value } => compare(Cmp::Lte, col, value, schema, cs)?,
        Node::Gt { col, value } => compare(Cmp::Gt, col, value, schema, cs)?,
        Node::Gte { col, value } => compare(Cmp::Gte, col, value, schema, cs)?,
        Node::StartsWith { col, value } => prefix(col, value, schema, cs)?,
        Node::NotStartsWith { col, value } => prefix(col, value, schema, cs)?.not(),

        Node::In { col, values } => membership(col, values, schema, cs)?,
        Node::NotIn { col, values } => membership(col, values, schema, cs)?.not(),
    })
}

/// A comparison operator, kept symbolic until the column type is known.
#[derive(Clone, Copy, Debug, PartialEq)]
enum Cmp {
    Eq,
    Ne,
    Lt,
    Lte,
    Gt,
    Gte,
}

impl Cmp {
    /// The comparison that holds exactly where this one does not, for a value
    /// that is neither null nor NaN.
    fn negate(self) -> Cmp {
        match self {
            Cmp::Eq => Cmp::Ne,
            Cmp::Ne => Cmp::Eq,
            Cmp::Lt => Cmp::Gte,
            Cmp::Gte => Cmp::Lt,
            Cmp::Lte => Cmp::Gt,
            Cmp::Gt => Cmp::Lte,
        }
    }

    fn apply(self, r: Reference, d: Datum) -> Predicate {
        match self {
            Cmp::Eq => r.equal_to(d),
            Cmp::Ne => r.not_equal_to(d),
            Cmp::Lt => r.less_than(d),
            Cmp::Lte => r.less_than_or_equal_to(d),
            Cmp::Gt => r.greater_than(d),
            Cmp::Gte => r.greater_than_or_equal_to(d),
        }
    }
}

fn is_float(ty: &PrimitiveType) -> bool {
    matches!(ty, PrimitiveType::Float | PrimitiveType::Double)
}

/// Whether a literal is zero, of either sign.
fn is_zero(d: &Datum) -> bool {
    match d.literal() {
        PrimitiveLiteral::Float(v) => v.0 == 0.0,
        PrimitiveLiteral::Double(v) => v.0 == 0.0,
        _ => false,
    }
}

/// Negative and positive zero, as literals of the column's own type.
fn zeros(ty: &PrimitiveType) -> (Datum, Datum) {
    match ty {
        PrimitiveType::Float => (Datum::float(-0.0_f32), Datum::float(0.0_f32)),
        _ => (Datum::double(-0.0), Datum::double(0.0)),
    }
}

/// A comparison on a float or double column, where a zero literal means both
/// zeros, as it does in R.
///
/// Rows are compared in IEEE 754's total order, which puts -0.0 strictly below
/// 0.0. Each comparison against zero is therefore restated so that the two
/// zeros fall on the same side of it: `x >= 0` becomes `x >= -0.0`, `x == 0`
/// becomes the range from -0.0 to 0.0, and so on.
fn float_compare(op: Cmp, r: &Reference, d: &Datum, ty: &PrimitiveType) -> Predicate {
    if !is_zero(d) {
        return op.apply(r.clone(), d.clone());
    }
    let (neg, pos) = zeros(ty);
    match op {
        Cmp::Eq => r
            .clone()
            .greater_than_or_equal_to(neg)
            .and(r.clone().less_than_or_equal_to(pos)),
        Cmp::Ne => r.clone().less_than(neg).or(r.clone().greater_than(pos)),
        Cmp::Lt => r.clone().less_than(neg),
        Cmp::Lte => r.clone().less_than_or_equal_to(pos),
        Cmp::Gt => r.clone().greater_than(pos),
        Cmp::Gte => r.clone().greater_than_or_equal_to(neg),
    }
}

/// `col <op> value`: TRUE where R says TRUE, FALSE where R says FALSE, and
/// neither for a null, or for a NaN, which compares as NA in R.
fn compare(op: Cmp, col: &str, value: &Json, schema: &Schema, cs: bool) -> RResult<Truth> {
    let (r, ty) = reference(col, schema, cs)?;
    let d = datum(value, &ty, col)?;
    if !is_float(&ty) {
        return Ok(Truth::new(
            op.apply(r.clone(), d.clone()),
            op.negate().apply(r, d),
        ));
    }
    Ok(Truth::new(
        float_compare(op, &r, &d, &ty).and(r.clone().is_not_nan()),
        float_compare(op.negate(), &r, &d, &ty).and(r.clone().is_not_nan()),
    ))
}

/// `is.na(col)`, which R makes TRUE for NaN as well as for a missing value.
fn missing(col: &str, schema: &Schema, cs: bool) -> RResult<Truth> {
    let (r, ty) = reference(col, schema, cs)?;
    Ok(if is_float(&ty) {
        Truth::new(
            r.clone().is_null().or(r.clone().is_nan()),
            r.clone().is_not_null().and(r.is_not_nan()),
        )
    } else {
        Truth::new(r.clone().is_null(), r.is_not_null())
    })
}

/// `col %in% values`, which in R is TRUE or FALSE and never NA: a missing
/// value, or a NaN, is simply not in the set.
fn membership(col: &str, values: &[Json], schema: &Schema, cs: bool) -> RResult<Truth> {
    let (r, ty) = reference(col, schema, cs)?;
    let datums = values
        .iter()
        .map(|v| datum(v, &ty, col))
        .collect::<RResult<Vec<_>>>()?;
    let float = is_float(&ty);

    // A zero in the set stands for both zeros, and cannot be looked up as one:
    // -0.0 and 0.0 compare unequal row by row, while the set, keyed on the
    // literal, holds only one of them. So it becomes a range test instead.
    let (zero, rest): (Vec<Datum>, Vec<Datum>) =
        datums.into_iter().partition(|d| float && is_zero(d));

    // An empty set matches nothing, and says so directly rather than letting an
    // empty IN list turn into a scan of everything.
    let mut t = if rest.is_empty() {
        Predicate::AlwaysFalse
    } else {
        r.clone().is_in(rest.clone())
    };
    let mut f = if rest.is_empty() {
        Predicate::AlwaysTrue
    } else {
        r.clone().is_not_in(rest)
    };
    if let Some(z) = zero.first() {
        t = t.or(float_compare(Cmp::Eq, &r, z, &ty));
        f = f.and(float_compare(Cmp::Ne, &r, z, &ty));
    }

    let absent = if float {
        r.clone().is_null().or(r.is_nan())
    } else {
        r.is_null()
    };
    Ok(Truth::new(t, f.or(absent)))
}

/// A prefix comparison, which Iceberg defines only over string columns.
///
/// `startsWith(id, "1")` against an `int` column parses cleanly on both sides:
/// R sees a column and a single string, and the prefix `"1"` converts to the
/// integer `1` here. So without this check the scan is planned against the
/// nonsense predicate `id STARTS WITH 1`. iceberg-rust does reject that, but only
/// from inside the statistics evaluators, and only for files that carry bounds:
/// a data file written without them would be read and its rows returned as
/// though the filter had been applied. The column and the operator are both in
/// hand here, so say so here instead.
///
/// `startsWith(NA, p)` is NA in R, and both halves are null for a null row, so
/// the pair needs nothing added.
fn prefix(col: &str, value: &Json, schema: &Schema, cs: bool) -> RResult<Truth> {
    let (r, ty) = reference(col, schema, cs)?;
    if !matches!(ty, PrimitiveType::String) {
        return Err(RError::Other(format!(
            "cannot use startsWith() on column {col:?}: it has Iceberg type \
             {ty}, and Iceberg compares prefixes only on string columns.\n\
             Select the column and filter it in R after icebergr_collect() \
             instead."
        )));
    }
    let d = datum(value, &ty, col)?;
    Ok(Truth::new(
        r.clone().starts_with(d.clone()),
        r.not_starts_with(d),
    ))
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
        if let Some(v) = value.as_i64() {
            return Ok(v);
        }
        // bit64::integer64 arrives as a digit string, because an int64 past
        // 2^53 cannot survive as a JSON number.
        if let Some(v) = value.as_str().and_then(|s| s.trim().parse::<i64>().ok()) {
            return Ok(v);
        }
        // A whole-numbered double, which is the form R sends anything past 2^53
        // in. The range check is not decoration: `f as i64` *saturates* in Rust,
        // so `id == 1e19` silently became `id == 9223372036854775807` and matched
        // whichever rows happen to hold i64::MAX -- a filter answering a
        // different question without saying so. The 32-bit branch below already
        // refuses an out-of-range value rather than clamping it; this is the
        // 64-bit branch agreeing with it.
        //
        // Bounded against 2^63 rather than against i64::MAX, because `i64::MAX as
        // f64` rounds *up* to 2^63: comparing against it would let the one value
        // through that cannot be converted. The message names no width for the
        // column, because this closure serves the timestamp and date arms too.
        if let Some(f) = value.as_f64().filter(|f| f.fract() == 0.0) {
            let limit = 9_223_372_036_854_775_808f64; // 2^63
            if f >= -limit && f < limit {
                return Ok(f as i64);
            }
            return Err(RError::Other(format!(
                "cannot compare column {col:?} (Iceberg type {ty}) against {f}: \
                 it is outside the range of a 64-bit integer."
            )));
        }
        Err(mismatch("a whole number"))
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
                "filtering on column {col:?} (Iceberg type {ty}) is not supported. \
                 Select the column and filter it in R instead; \
                 icebergr_spec_support() lists what this build does support."
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

#[cfg(test)]
mod tests {
    use super::*;

    fn json(text: &str) -> Json {
        serde_json::from_str(text).expect("test literal is valid JSON")
    }

    #[test]
    fn a_long_literal_past_i64_is_refused_rather_than_clamped() {
        // The exact text R emits for 1e19: format(1e19, digits = 17,
        // scientific = FALSE, trim = TRUE). serde_json holds it as a u64, so
        // as_i64() declines it and the f64 fallback used to saturate to
        // i64::MAX -- turning `id == 1e19` into a filter that matches rows
        // holding 9223372036854775807 and reports nothing amiss.
        let err = datum(&json("10000000000000000000"), &PrimitiveType::Long, "id")
            .expect_err("1e19 does not fit an i64");
        assert!(
            err.to_string()
                .contains("outside the range of a 64-bit integer"),
            "{err}"
        );
    }

    #[test]
    fn a_long_literal_inside_the_range_still_converts() {
        // Past 2^53, so it arrives as a double and takes the fallback -- the
        // path the range check guards. It has to keep working.
        assert_eq!(
            datum(&json("1e18"), &PrimitiveType::Long, "id").unwrap(),
            Datum::long(1_000_000_000_000_000_000i64)
        );
        // And the boundaries themselves convert rather than being refused.
        assert_eq!(
            datum(&json("-9223372036854775808"), &PrimitiveType::Long, "id").unwrap(),
            Datum::long(i64::MIN)
        );
    }

    #[test]
    fn an_integer64_digit_string_is_still_exact() {
        // bit64::integer64 comes over as a string precisely so that this value
        // does not become 9007199254740992 on the way.
        assert_eq!(
            datum(&json("\"9007199254740993\""), &PrimitiveType::Long, "id").unwrap(),
            Datum::long(9_007_199_254_740_993i64)
        );
    }

    #[test]
    fn a_fractional_long_literal_names_the_mismatch() {
        let err =
            datum(&json("2.5"), &PrimitiveType::Long, "id").expect_err("2.5 is not a whole number");
        assert!(err.to_string().contains("expected a whole number"), "{err}");
    }
}
