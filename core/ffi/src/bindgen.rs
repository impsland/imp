//! Writes the Swift bindings from the built library (`apple/scripts/apple.sh core` runs it).

fn main() {
    uniffi::uniffi_bindgen_main()
}
