//! Hands the build's model service addresses to the code as `IMP_RESELLER_URL` and
//! `IMP_RESELLER_ISSUANCE_URL`. An environment variable of that name wins, else the last assignment in
//! `apple/Config/Reseller.local.xcconfig` or `apple/Config/Reseller.xcconfig`, the file the Mac and iPhone
//! apps are built from too. Empty or missing means the person adds a service by hand.

use std::path::Path;

const NAMES: [&str; 2] = ["IMP_RESELLER_URL", "IMP_RESELLER_ISSUANCE_URL"];
const FILES: [&str; 2] = [
    "../apple/Config/Reseller.local.xcconfig",
    "../apple/Config/Reseller.xcconfig",
];

/// The last value `name` is given in an xcconfig. `$()` keeps the slashes of `https://` from being a
/// comment there, so it is dropped.
fn assigned(text: &str, name: &str) -> Option<String> {
    text.lines()
        .filter_map(|line| {
            let (key, value) = line.split_once('=')?;
            (key.trim() == name).then(|| value.trim().replace("$()", ""))
        })
        .next_back()
        .filter(|value| !value.is_empty())
}

fn main() {
    let dir = std::env::var("CARGO_MANIFEST_DIR").unwrap_or_default();
    for file in FILES {
        println!("cargo:rerun-if-changed={file}");
    }
    for name in NAMES {
        println!("cargo:rerun-if-env-changed={name}");
        let value = std::env::var(name).ok().or_else(|| {
            FILES.iter().find_map(|file| {
                let text = std::fs::read_to_string(Path::new(&dir).join(file)).ok()?;
                assigned(&text, name)
            })
        });
        println!("cargo:rustc-env={name}={}", value.unwrap_or_default());
    }
}
