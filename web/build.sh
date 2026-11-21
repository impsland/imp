#!/bin/sh
# Builds the link node for the web page (web/link) into web/app/pkg.
#
# Needs rustup's toolchain with the wasm32-unknown-unknown target, clang with a WebAssembly backend (ring
# compiles C) and wasm-bindgen-cli at the version in Cargo.lock:
#   rustup target add wasm32-unknown-unknown
#   brew install llvm
#   cargo install wasm-bindgen-cli --version 0.2.129
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
toolchain=$(sed -n 's/^channel = "\(.*\)"/\1/p' "$root/rust-toolchain.toml")
profile=${PROFILE:-release}

# Another rustc earlier in PATH (Homebrew's) has no wasm32 standard library, so use rustup's.
if command -v rustup > /dev/null 2>&1; then
  bin=$(dirname "$(rustup which --toolchain "$toolchain" rustc)")
  export RUSTC="$bin/rustc"
  cargo="$bin/cargo"
else
  cargo=cargo
fi

# Apple's clang has no WebAssembly backend.
if [ -z "${CC_wasm32_unknown_unknown:-}" ]; then
  for llvm in /opt/homebrew/opt/llvm/bin /usr/local/opt/llvm/bin; do
    if [ -x "$llvm/clang" ]; then
      export CC_wasm32_unknown_unknown="$llvm/clang"
      export AR_wasm32_unknown_unknown="$llvm/llvm-ar"
      break
    fi
  done
fi

export CARGO_TARGET_WASM32_UNKNOWN_UNKNOWN_RUSTFLAGS='--cfg getrandom_backend="wasm_js"'
export CARGO_TARGET_DIR="$root/target/web"

"$cargo" build --locked -p imp-web --target wasm32-unknown-unknown --profile "$profile"
# Cargo writes the dev profile to `debug`.
[ "$profile" = dev ] && out=debug || out=$profile
wasm-bindgen --target web --no-typescript --out-dir "$root/web/app/pkg" \
  "$root/target/web/wasm32-unknown-unknown/$out/imp_web.wasm"
# The Imp is drawn by the Den gallery's renderer, and the colours are the design tokens: one copy each.
cp "$root/server/den/web/assets/imp.js" "$root/web/app/pkg/imp.js"
cp "$root/extension/tokens.css" "$root/web/app/pkg/tokens.css"
# The page's icon is the browser extension's.
mkdir -p "$root/web/app/pkg/icons"
cp "$root/extension/icons/16.png" "$root/extension/icons/32.png" "$root/extension/icons/128.png" "$root/web/app/pkg/icons/"
echo "Built web/app/pkg"
