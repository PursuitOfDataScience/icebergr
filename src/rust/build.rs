//! Records which iceberg-rust and arrow this build resolved to.
//!
//! `icebergr_spec_support()` reports both, and they used to be typed into
//! `lib.rs` by hand, which nothing checked: a dependency bump could leave the
//! package telling users it ran a version it did not, and the test for it
//! compared one hardcoded string against another. Cargo tells a crate nothing
//! about the versions of its dependencies, so this reads the lock file, which is
//! what the build actually used. It ships in the tarball because an offline
//! build needs it anyway.

use std::path::PathBuf;

/// The version `Cargo.lock` records for the package called exactly `name`.
fn locked_version(lock: &str, name: &str) -> Option<String> {
    let header = format!("name = \"{name}\"");
    let mut lines = lock.lines();
    while let Some(line) = lines.next() {
        if line.trim() == header {
            let version = lines.next()?.trim();
            let version = version.strip_prefix("version = \"")?.strip_suffix('"')?;
            return Some(version.to_string());
        }
    }
    None
}

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=Cargo.lock");

    // Never a reason to fail the build: "unknown" is a worse answer than the
    // real version, and a much better one than no package at all.
    let lock = std::env::var_os("CARGO_MANIFEST_DIR")
        .map(|dir| PathBuf::from(dir).join("Cargo.lock"))
        .and_then(|path| std::fs::read_to_string(path).ok())
        .unwrap_or_default();
    for (name, var) in [
        ("iceberg", "ICEBERGR_ICEBERG_VERSION"),
        ("arrow", "ICEBERGR_ARROW_VERSION"),
    ] {
        let version = locked_version(&lock, name).unwrap_or_else(|| "unknown".to_string());
        println!("cargo:rustc-env={var}={version}");
    }
}
