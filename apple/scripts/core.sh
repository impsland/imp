#!/usr/bin/env bash
# Builds the portable core (imp-core, through core/ffi) for the Apple apps:
#   apple/Frameworks/ImpCoreFFI.xcframework  the static library and its C header
#   apple/Sources/ImpCore/ImpCore.swift      the Swift bindings (UniFFI)
# Both are build output and are not committed.
#
#   apple/scripts/core.sh [mac|mac-universal|ios-sim|ios]...   (default: mac ios-sim)
#
# The default covers `make build`, `make test` and `make ios`, so switching between them never swaps the
# framework. The framework is replaced only when something in it changed, so Xcode keeps its caches.
#
# CORE_PROFILE=release builds the shipping profile. The default, apple-dev, rebuilds quickly.
set -euo pipefail
cd "$(dirname "$0")/../.."

PROFILE="${CORE_PROFILE:-apple-dev}"
TOOLCHAIN="$(sed -n 's/^channel = "\(.*\)"$/\1/p' rust-toolchain.toml)"

# rustup's toolchain, not another cargo found first on PATH: only rustup has the Apple targets.
command -v rustup >/dev/null || { echo "error: the core needs rustup (https://rustup.rs)" >&2; exit 1; }
rustup toolchain install "$TOOLCHAIN" --profile minimal --no-self-update >/dev/null 2>&1 || true
export PATH="$(dirname "$(rustup +"$TOOLCHAIN" which cargo)"):$PATH"

if (( $# )); then SLICES=("$@"); else SLICES=(mac ios-sim); fi
TARGETS=()
for slice in "${SLICES[@]}"; do
  case "$slice" in
    mac) TARGETS+=("$(uname -m | sed 's/arm64/aarch64/')-apple-darwin") ;;
    mac-universal) TARGETS+=(aarch64-apple-darwin x86_64-apple-darwin) ;;
    ios-sim) TARGETS+=(aarch64-apple-ios-sim) ;;
    ios) TARGETS+=(aarch64-apple-ios) ;;
    *) echo "error: unknown slice $slice (mac, mac-universal, ios-sim, ios)" >&2; exit 1 ;;
  esac
done
rustup +"$TOOLCHAIN" target add "${TARGETS[@]}" >/dev/null

for target in "${TARGETS[@]}"; do
  MACOSX_DEPLOYMENT_TARGET=15.0 IPHONEOS_DEPLOYMENT_TARGET=18.0 \
    cargo build --locked -p imp-ffi --lib --profile "$PROFILE" --target "$target"
done

OUT=apple/.build/core
LIB=libimp_ffi.a
rm -rf "$OUT" && mkdir -p "$OUT/headers"

# The bindings come from the library's own metadata.
cargo run --locked -q -p imp-ffi --bin uniffi-bindgen -- generate \
  --library "target/${TARGETS[0]}/$PROFILE/$LIB" --language swift --out-dir "$OUT/gen"
mkdir -p apple/Sources/ImpCore
cmp -s "$OUT/gen/ImpCore.swift" apple/Sources/ImpCore/ImpCore.swift || cp "$OUT/gen/ImpCore.swift" apple/Sources/ImpCore/ImpCore.swift
cp "$OUT/gen/ImpCoreFFI.h" "$OUT/headers/"
printf 'module ImpCoreFFI {\n    header "ImpCoreFFI.h"\n    export *\n}\n' > "$OUT/headers/module.modulemap"

# One library per platform: the Mac's two architectures are joined first.
ARGS=()
add() { ARGS+=(-library "$1" -headers "$OUT/headers"); }
macs=() ; for t in "${TARGETS[@]}"; do [[ "$t" == *-apple-darwin ]] && macs+=("target/$t/$PROFILE/$LIB"); done
if (( ${#macs[@]} > 1 )); then
  mkdir -p "$OUT/mac" && lipo -create "${macs[@]}" -output "$OUT/mac/$LIB" && add "$OUT/mac/$LIB"
elif (( ${#macs[@]} == 1 )); then
  add "${macs[0]}"
fi
for t in "${TARGETS[@]}"; do [[ "$t" == *-apple-ios* ]] && add "target/$t/$PROFILE/$LIB"; done

rm -rf "$OUT/ImpCoreFFI.xcframework"
xcodebuild -create-xcframework "${ARGS[@]}" -output "$OUT/ImpCoreFFI.xcframework" >/dev/null
mkdir -p apple/Frameworks apple/Sources/ImpCore
if ! diff -rq "$OUT/ImpCoreFFI.xcframework" apple/Frameworks/ImpCoreFFI.xcframework >/dev/null 2>&1; then
  rm -rf apple/Frameworks/ImpCoreFFI.xcframework
  mv "$OUT/ImpCoreFFI.xcframework" apple/Frameworks/
fi
echo "Built the core for ${SLICES[*]} ($PROFILE)"
