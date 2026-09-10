//! Turning Rust errors into R conditions, without leaking secrets.
//!
//! Catalog configuration carries bearer tokens, secret access keys and
//! signing credentials. An error message that echoes the offending
//! configuration is an excellent way to write a token into a knitr cache, a CI
//! log, or an R history file, so nothing here ever formats a property *value*.
//! Only key names are reported.

use extendr_api::Error as RError;

pub type RResult<T> = std::result::Result<T, RError>;

/// Query and form parameters whose value is a credential.
///
/// Matched case-insensitively, since S3 uses `X-Amz-Signature` in a query
/// string and `x-amz-signature` in a signed header list.
const SECRET_PARAMS: &[&str] = &[
    "x-amz-signature",
    "x-amz-credential",
    "x-amz-security-token",
    "client_secret",
    "client_id",
    "access_token",
    "refresh_token",
    "id_token",
    "assertion",
    "password",
    "signature",
];

/// Strip `user:password@` out of every URL in `text`.
fn scrub_userinfo(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(i) = rest.find("://") {
        let (head, tail) = rest.split_at(i + 3);
        out.push_str(head);
        // The authority runs to the first delimiter, or to the end of the text.
        let end = tail
            .find(|c: char| c == '/' || c == '?' || c == '#' || c.is_whitespace())
            .unwrap_or(tail.len());
        let (authority, after) = tail.split_at(end);
        match authority.rfind('@') {
            Some(at) => {
                out.push_str("<redacted>@");
                out.push_str(&authority[at + 1..]);
            }
            None => out.push_str(authority),
        }
        rest = after;
    }
    out.push_str(rest);
    out
}

/// Replace the value of any `SECRET_PARAMS` key with a placeholder.
fn scrub_params(text: &str) -> String {
    let lower = text.to_ascii_lowercase();
    let mut cuts: Vec<(usize, usize)> = Vec::new();
    for key in SECRET_PARAMS {
        let mut from = 0;
        while let Some(rel) = lower[from..].find(key) {
            let start = from + rel;
            from = start + key.len();
            // Only a real key=value, not a substring of a longer word.
            if start > 0 {
                let prev = lower.as_bytes()[start - 1];
                if prev.is_ascii_alphanumeric() || prev == b'_' || prev == b'-' {
                    continue;
                }
            }
            let after_key = &text[from..];
            let sep = after_key
                .find(|c: char| !c.is_whitespace())
                .filter(|_| true)
                .unwrap_or(0);
            let bytes = after_key.as_bytes();
            if bytes.get(sep) != Some(&b'=') && bytes.get(sep) != Some(&b':') {
                continue;
            }
            let vstart = from + sep + 1;
            let value = &text[vstart..];
            let vlen = value
                .find(|c: char| {
                    c == '&'
                        || c == '"'
                        || c == '\''
                        || c == ')'
                        || c == ','
                        || c == ';'
                        || c.is_whitespace()
                })
                .unwrap_or(value.len());
            if vlen > 0 {
                cuts.push((vstart, vstart + vlen));
            }
        }
    }
    if cuts.is_empty() {
        return text.to_string();
    }
    cuts.sort_unstable();
    let mut out = String::with_capacity(text.len());
    let mut at = 0;
    for (start, end) in cuts {
        if start < at {
            continue; // overlapping match already covered
        }
        out.push_str(&text[at..start]);
        out.push_str("<redacted>");
        at = end;
    }
    out.push_str(&text[at..]);
    out
}

/// Remove credentials an upstream error may have echoed back.
///
/// The module promise above is that nothing here formats a property *value* --
/// true of the key lists, and false of the upstream error itself, which is
/// interpolated verbatim. `reqwest`'s `Display` appends `for url (...)`, so a
/// `uri` carrying `user:password@host` puts the password into an R condition,
/// and from there into a knitr cache or a CI log; an OAuth2 error body can echo
/// the submitted `client_secret`, and an opendal error an `X-Amz-Signature`.
/// This closes the gap the promise already claimed to cover.
///
/// Hand-rolled rather than done with a regex on purpose: the vendored
/// dependency tree is already at CRAN's size limit, and this needs no new
/// crate.
pub fn scrub<E: std::fmt::Display>(e: E) -> String {
    scrub_params(&scrub_userinfo(&e.to_string()))
}

/// Wrap an error with context.
pub fn ctx<E: std::fmt::Display>(what: &str, e: E) -> RError {
    RError::Other(format!("{what}: {}", scrub(e)))
}

/// Report a failure that involves catalog configuration.
///
/// Lists the property keys that were supplied so the user can see what the
/// catalog was given, and deliberately never their values.
pub fn config_err<E: std::fmt::Display>(what: &str, keys: &[String], e: E) -> RError {
    let listed = if keys.is_empty() {
        "none".to_string()
    } else {
        let mut sorted = keys.to_vec();
        sorted.sort();
        sorted.join(", ")
    };
    RError::Other(format!(
        "{what}: {}\nProperties supplied (keys only, values withheld): {listed}",
        scrub(e)
    ))
}

/// An error for a feature that exists in Iceberg but is not compiled in.
///
/// Every caller is behind `#[cfg(not(feature = ...))]`, so a build with every
/// optional feature turned on has no use for it. That is a complete build, not
/// a mistake, and it should not warn.
#[allow(dead_code)]
pub fn not_compiled_in(what: &str, feature: &str) -> RError {
    RError::Other(format!(
        "{what} is not available in this build of icebergr.\n\
         It requires the optional Cargo feature \"{feature}\", which is off by \
         default because it substantially enlarges the dependency tree.\n\
         Reinstall from source with:\n  \
         ICEBERGR_CARGO_FEATURES={feature} R CMD INSTALL --preclean .\n\
         See vignette(\"catalog-configuration\", package = \"icebergr\")."
    ))
}

// Gaps in iceberg-rust itself are reported from R rather than from here: see
// icebergr_spec_support(), which can describe them without a round trip into
// Rust and without the caller having to trigger the failure first.

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn userinfo_is_removed_from_a_url() {
        let got = scrub("error sending request for url (https://svc:s3cr3t@catalog/v1/config)");
        assert!(!got.contains("s3cr3t"), "{got}");
        assert!(got.contains("<redacted>@catalog/v1/config"), "{got}");
    }

    #[test]
    fn a_url_without_userinfo_is_untouched() {
        let text = "for url (https://catalog.example.com/v1/config)";
        assert_eq!(scrub(text), text);
    }

    #[test]
    fn several_urls_are_all_handled() {
        let got = scrub("https://a:b@one/ then https://c:d@two/x");
        assert!(!got.contains("b@") && !got.contains("d@"), "{got}");
        assert_eq!(got.matches("<redacted>@").count(), 2, "{got}");
    }

    #[test]
    fn secret_query_parameters_are_removed() {
        let got = scrub("403: /obj?X-Amz-Credential=AKIA123%2Fus&X-Amz-Signature=deadbeef&foo=1");
        assert!(!got.contains("deadbeef"), "{got}");
        assert!(!got.contains("AKIA123"), "{got}");
        assert!(got.contains("foo=1"), "the innocent parameter survives: {got}");
    }

    #[test]
    fn a_secret_in_a_form_body_is_removed() {
        let got = scrub("invalid_client: client_secret=hunter2, grant_type=client_credentials");
        assert!(!got.contains("hunter2"), "{got}");
        assert!(got.contains("grant_type=client_credentials"), "{got}");
    }

    #[test]
    fn a_key_that_is_only_a_substring_is_left_alone() {
        // "my_password_hint" is not the `password` parameter.
        let text = "field my_password_hint=abc is not a credential";
        assert_eq!(scrub(text), text);
    }

    #[test]
    fn ordinary_text_is_unchanged() {
        let text = "Table db.events does not exist in namespace db";
        assert_eq!(scrub(text), text);
    }

    #[test]
    fn config_err_still_lists_keys_and_scrubs_the_cause() {
        let keys = vec!["token".to_string(), "uri".to_string()];
        let msg = config_err("could not connect", &keys, "url (https://u:p@h/v1)").to_string();
        assert!(!msg.contains(":p@"), "{msg}");
        assert!(msg.contains("token, uri"), "{msg}");
    }
}
