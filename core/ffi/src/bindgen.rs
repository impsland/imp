//! Writes the Swift bindings from the built library (`apple/scripts/core.sh` runs it).

fn main() {
    uniffi::uniffi_bindgen_main()
}
