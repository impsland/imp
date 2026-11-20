#!/usr/bin/env bash
#
# The build tool for the Apple apps. It builds the Rust core, the Mac app and its installer, the
# iPhone app, and the Homebrew cask, and it keeps the String Catalogs in step with the code.
#
#   apple/scripts/apple.sh help             lists the commands
#   apple/scripts/apple.sh <command> -h     explains one command and its options
#
# Every command runs from the repository root, wherever it is called from. The script needs only
# Bash 3.2 (the version macOS ships), the Xcode command line tools and, for some commands, rustup,
# XcodeGen or dmgbuild. Each command says what it needs in its help.

set -euo pipefail

PROG="apple/scripts/apple.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# Paths every command agrees on, relative to the repository root.
PACKAGE="apple"                                   # the Swift package of the Mac app
APP="build/Imp.app"                               # what `app` makes and `dmg` packs
DMG="build/Imp.dmg"                               # what `dmg` makes
INFO_PLIST="apple/Resources/Info.plist"
ENTITLEMENTS="apple/Resources/Imp.entitlements"
CATALOGS="apple/Resources/Localization"           # the Mac app's String Catalogs
IOS_PROJECT="apple/iOS/ImpPhone.xcodeproj"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# The Swift driver. Set SWIFT to use another one, for example SWIFT=swift for a toolchain on PATH.
read -r -a SWIFT_CMD <<< "${SWIFT:-xcrun swift}"

# =============================================================================================
# Helpers
# =============================================================================================

# Prints a message to stderr and stops with status 1.
die() {
  echo "error: $*" >&2
  exit 1
}

# Prints a usage mistake and the command's help to stderr, then stops with status 2.
usage_error() {
  local command="$1"
  shift
  echo "error: $*" >&2
  echo >&2
  show_help "$command" >&2
  exit 2
}

# Stops with a hint on how to install a tool when it is missing.
require() {
  local tool="$1" hint="$2"
  command -v "$tool" > /dev/null || die "$tool is missing. $hint"
}

# A scratch folder for the whole run, removed when the script exits. Call `scratch` once, then use $WORK.
WORK=""
cleanup() {
  if [[ -n "$WORK" ]]; then rm -rf "$WORK"; fi
}
trap cleanup EXIT
scratch() {
  if [[ -z "$WORK" ]]; then WORK="$(mktemp -d "${TMPDIR:-/tmp}/imp-apple.XXXXXX")"; fi
}

# Runs the Swift driver.
swift_run() {
  "${SWIFT_CMD[@]}" "$@"
}

# Compiles each String Catalog into <language>.lproj folders inside the given Resources folder,
# which is where Bundle.main looks for translations.
compile_catalogs() {
  local resources="$1" catalog
  for catalog in "$CATALOGS"/*.xcstrings; do
    xcrun xcstringstool compile "$catalog" --output-directory "$resources"
  done
}

# Writes the iPhone app's Xcode project from apple/iOS/project.yml.
generate_ios_project() {
  require xcodegen "Install it with: brew install xcodegen"
  (cd apple/iOS && xcodegen generate --quiet)
}

# Runs xcodebuild without one line of noise. When building for "any iPhone", Xcode logs that its
# placeholder device has no iOS version. Everything else xcodebuild prints still shows.
xcodebuild_filtered() {
  local noise="IDESchemeActionsInvocationRecord"
  xcodebuild "$@" > >(grep -v "$noise" || true) 2> >(grep -v "$noise" >&2 || true)
}

# =============================================================================================
# core: the Rust core for the apps
# =============================================================================================

help_core() {
  cat << EOF
Usage: $PROG core [--release] [SLICE...]

Builds the portable Rust core (imp-engine, through engine/ffi) for the Apple apps:

  apple/Frameworks/ImpCoreFFI.xcframework   the static library and its C header
  apple/Sources/ImpCore/ImpCore.swift       the Swift bindings (UniFFI)

Both are build output and are not committed. Each one is replaced only when its content changed,
so Xcode keeps its caches.

Slices (default: mac ios-sim, which covers make build, make test and make ios):
  mac             this Mac's architecture
  mac-universal   Apple silicon and Intel Macs
  ios-sim         the iPhone Simulator on Apple silicon
  ios             real iPhones

Options:
  --release       build the shipping profile (default: apple-dev, which builds faster)
  -h, --help      show this help

Environment:
  CORE_PROFILE    the Cargo profile, the same as --release when set to release

Needs rustup (https://rustup.rs). The Rust version comes from rust-toolchain.toml.
EOF
}

cmd_core() {
  local profile="${CORE_PROFILE:-apple-dev}"
  local slices=()
  while (( $# )); do
    case "$1" in
      --release) profile="release" ;;
      -h | --help) help_core; return ;;
      -*) usage_error core "unknown option $1" ;;
      *) slices+=("$1") ;;
    esac
    shift
  done
  if (( ${#slices[@]} == 0 )); then slices=(mac ios-sim); fi

  # Map each slice to its Rust targets.
  local targets=() slice
  for slice in "${slices[@]}"; do
    case "$slice" in
      mac) targets+=("$(uname -m | sed 's/arm64/aarch64/')-apple-darwin") ;;
      mac-universal) targets+=(aarch64-apple-darwin x86_64-apple-darwin) ;;
      ios-sim) targets+=(aarch64-apple-ios-sim) ;;
      ios) targets+=(aarch64-apple-ios) ;;
      *) usage_error core "unknown slice $slice" ;;
    esac
  done

  # Use rustup's toolchain, not another cargo found first on PATH. Only rustup has the Apple targets.
  require rustup "Install it from https://rustup.rs"
  local toolchain
  toolchain="$(sed -n 's/^channel = "\(.*\)"$/\1/p' rust-toolchain.toml)"
  rustup toolchain install "$toolchain" --profile minimal --no-self-update > /dev/null 2>&1 || true
  PATH="$(dirname "$(rustup +"$toolchain" which cargo)"):$PATH"
  export PATH
  rustup +"$toolchain" target add "${targets[@]}" > /dev/null

  local target
  for target in "${targets[@]}"; do
    MACOSX_DEPLOYMENT_TARGET=15.0 IPHONEOS_DEPLOYMENT_TARGET=18.0 \
      cargo build --locked -p imp-ffi --lib --profile "$profile" --target "$target"
  done

  local out="apple/.build/core" lib="libimp_ffi.a"
  rm -rf "$out"
  mkdir -p "$out/headers" apple/Sources/ImpCore apple/Frameworks

  # The Swift bindings come from the metadata inside the built library.
  cargo run --locked -q -p imp-ffi --bin uniffi-bindgen -- generate \
    --library "target/${targets[0]}/$profile/$lib" --language swift --out-dir "$out/gen"
  if ! cmp -s "$out/gen/ImpCore.swift" apple/Sources/ImpCore/ImpCore.swift; then
    cp "$out/gen/ImpCore.swift" apple/Sources/ImpCore/ImpCore.swift
  fi
  cp "$out/gen/ImpCoreFFI.h" "$out/headers/"
  printf 'module ImpCoreFFI {\n    header "ImpCoreFFI.h"\n    export *\n}\n' > "$out/headers/module.modulemap"

  # An XCFramework holds one library per platform, so the Mac's architectures are joined first.
  local framework_args=() mac_libs=()
  for target in "${targets[@]}"; do
    if [[ "$target" == *-apple-darwin ]]; then mac_libs+=("target/$target/$profile/$lib"); fi
  done
  if (( ${#mac_libs[@]} > 1 )); then
    mkdir -p "$out/mac"
    lipo -create "${mac_libs[@]}" -output "$out/mac/$lib"
    framework_args+=(-library "$out/mac/$lib" -headers "$out/headers")
  elif (( ${#mac_libs[@]} == 1 )); then
    framework_args+=(-library "${mac_libs[0]}" -headers "$out/headers")
  fi
  for target in "${targets[@]}"; do
    if [[ "$target" == *-apple-ios* ]]; then
      framework_args+=(-library "target/$target/$profile/$lib" -headers "$out/headers")
    fi
  done

  xcodebuild -create-xcframework "${framework_args[@]}" -output "$out/ImpCoreFFI.xcframework" > /dev/null
  if ! diff -rq "$out/ImpCoreFFI.xcframework" apple/Frameworks/ImpCoreFFI.xcframework > /dev/null 2>&1; then
    rm -rf apple/Frameworks/ImpCoreFFI.xcframework
    mv "$out/ImpCoreFFI.xcframework" apple/Frameworks/
  fi
  echo "Built the core for ${slices[*]} ($profile)"
}

# =============================================================================================
# app: the Mac app bundle
# =============================================================================================

help_app() {
  cat << EOF
Usage: $PROG app [--universal | --arch ARCH...] [--version VERSION] [--debug]

Builds $APP: compiles the app, renders its icon, compiles the translations, adds the browser
extension and code-signs the bundle. Build the core first ($PROG core).

Options:
  --universal         build for Apple silicon and Intel (the same as --arch arm64 --arch x86_64)
  --arch ARCH         build for one architecture, repeat for more (default: this Mac's)
  --version VERSION   stamp this version into Info.plist (default: keep the one in $INFO_PLIST)
  --debug             build the debug configuration (default: release)
  -h, --help          show this help

Environment:
  SWIFT               the Swift driver (default: xcrun swift)
  ARCHS, VERSION, CONFIG   the same as --arch, --version and --debug (CONFIG=debug)
  IMP_DEVELOPER_ID    a "Developer ID Application" certificate. Signs for notarization with the
                      hardened runtime and a secure timestamp.
  IMP_SIGN_IDENTITY   another signing identity (releases use "Imp Release Signing")

Without either identity, the app is signed with the first "Apple Development" identity in the
keychain, or ad hoc when there is none. A stable identity matters: macOS ties Keychain access and
the Microphone permission to the signature, so an ad hoc build asks for them again after every
rebuild.
EOF
}

cmd_app() {
  local config="${CONFIG:-release}" version="${VERSION:-}"
  local archs=()
  read -r -a archs <<< "${ARCHS:-}"
  while (( $# )); do
    case "$1" in
      --universal) archs=(arm64 x86_64) ;;
      --arch) [[ $# -ge 2 ]] || usage_error app "--arch needs a value"; archs+=("$2"); shift ;;
      --version) [[ $# -ge 2 ]] || usage_error app "--version needs a value"; version="$2"; shift ;;
      --debug) config="debug" ;;
      -h | --help) help_app; return ;;
      *) usage_error app "unknown argument $1" ;;
    esac
    shift
  done
  # CONFIG may come from the iPhone side (Release or Debug), and Swift wants lowercase.
  config="$(echo "$config" | tr '[:upper:]' '[:lower:]')"
  case "$config" in
    release | debug) ;;
    *) usage_error app "the configuration is release or debug, not $config" ;;
  esac

  local build_args=(--package-path "$PACKAGE" -c "$config") arch
  for arch in ${archs[@]+"${archs[@]}"}; do build_args+=(--arch "$arch"); done
  swift_run build "${build_args[@]}" --product Imp
  local bin_dir binary bundle
  bin_dir="$(swift_run build "${build_args[@]}" --show-bin-path)"
  binary="$bin_dir/Imp"

  # Render the icon first, then assemble the bundle in a staging folder and move it into place in
  # one step. A bundle built in place let Finder and LaunchServices see and cache a half-made app
  # whose Info.plist named AppIcon before AppIcon.icns existed. Adding files to Contents/Resources
  # never changes the date of the bundle folder, so that generic icon stayed.
  local iconset="build/AppIcon.iconset" stage="build/.staging/Imp.app"
  rm -rf "$iconset" "$stage"
  "$binary" --render-icon "$iconset"

  mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources"
  cp "$binary" "$stage/Contents/MacOS/Imp"
  cp "$INFO_PLIST" "$stage/Contents/Info.plist"
  if [[ -n "$version" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" \
      -c "Set :CFBundleVersion $version" "$stage/Contents/Info.plist"
  fi
  iconutil -c icns "$iconset" -o "$stage/Contents/Resources/AppIcon.icns"
  compile_catalogs "$stage/Contents/Resources"
  # The packages' resource bundles (SwiftFlow's words for VoiceOver). A package finds its bundle through
  # `Bundle.module`, which looks in Contents/Resources first and stops the app when it isn't anywhere.
  for bundle in "$bin_dir"/*.bundle; do
    if [[ -e "$bundle" ]]; then cp -R "$bundle" "$stage/Contents/Resources/"; fi
  done
  # The browser extension rides along. Settings › Tools › Browser shows it, to add to a browser.
  cp -R extension "$stage/Contents/Resources/Browser Extension"
  # The licences of the libraries the app is built with (SwiftFlow is MIT: its notice must ship with it).
  cp THIRD_PARTY_NOTICES.md "$stage/Contents/Resources/THIRD_PARTY_NOTICES.md"

  sign_app "$stage"

  rm -rf "$APP"
  mv "$stage" "$APP"
  rmdir build/.staging 2> /dev/null || true
  # A fresh date and a fresh registration, so Finder and the Dock show the new icon right away.
  touch "$APP"
  if [[ -x "$LSREGISTER" ]]; then "$LSREGISTER" -f "$APP" || true; fi
  echo "Built $APP"
}

# Signs an app bundle with the best identity available (see `help app`).
sign_app() {
  local bundle="$1"
  local args=(--force --options runtime --entitlements "$ENTITLEMENTS")
  local identity
  if [[ -n "${IMP_DEVELOPER_ID:-}" ]]; then
    # Notarization needs the hardened runtime and a secure timestamp from Apple.
    codesign "${args[@]}" --timestamp --sign "$IMP_DEVELOPER_ID" "$bundle"
    echo "Signed with $IMP_DEVELOPER_ID (Developer ID)"
    return
  fi
  identity="${IMP_SIGN_IDENTITY:-}"
  if [[ -z "$identity" ]]; then
    identity="$(security find-identity -v -p codesigning 2> /dev/null \
      | awk -F'"' '/Apple Development/ { print $2; exit }')"
  fi
  if [[ -n "$identity" ]]; then
    codesign "${args[@]}" --sign "$identity" "$bundle"
    echo "Signed with $identity"
  else
    codesign "${args[@]}" --sign - "$bundle"
    echo "Signed ad hoc. macOS asks for permissions again after each rebuild."
  fi
}

# =============================================================================================
# dmg: the installer disk image
# =============================================================================================

help_dmg() {
  cat << EOF
Usage: $PROG dmg

Packs $APP into $DMG: the installer window shows Imp next to a link to Applications, on a
background the app renders itself. Build the app first ($PROG app).

The disk image stays unsigned. Gatekeeper checks a signed disk image when it is opened and blocks
one whose certificate is not Apple's, while an unsigned one just opens. The app inside is signed,
so a download asks for permission once, when Imp first launches.

Environment:
  IMP_DEVELOPER_ID   also sign the disk image with this Developer ID certificate
  IMP_NOTARY_*       notarize the app before packing it, and the image after (see: help notarize)
  DMGBUILD           the dmgbuild command (default: dmgbuild)

Needs dmgbuild: pipx install dmgbuild
EOF
}

cmd_dmg() {
  case "${1:-}" in
    -h | --help) help_dmg; return ;;
    "") ;;
    *) usage_error dmg "unexpected argument $1" ;;
  esac
  local dmgbuild="${DMGBUILD:-dmgbuild}"
  require "$dmgbuild" "Install it with: pipx install dmgbuild"
  [[ -d "$APP" ]] || die "$APP is missing. Run $PROG app first."

  cmd_notarize "$APP"

  scratch
  local background="$WORK/dmg-background" settings="$WORK/dmg-settings.py"
  "$APP/Contents/MacOS/Imp" --render-dmg-background "$background"
  write_dmg_settings "$settings"
  rm -f "$DMG"
  "$dmgbuild" -s "$settings" -D app="$APP" -D background="$background/background.png" Imp "$DMG"

  if [[ -n "${IMP_DEVELOPER_ID:-}" ]]; then
    codesign --force --timestamp --sign "$IMP_DEVELOPER_ID" "$DMG"
    cmd_notarize "$DMG"
  fi
  echo "Built $DMG"
}

# Writes the dmgbuild settings: Imp.app next to a link to Applications, on the rendered background.
# The window size, icon size and icon centres match IconRenderer.DMGBackground in the app.
# The mounted volume shows the app's icon. The .dmg file itself keeps the system's disk image icon,
# because a custom file icon lives in a resource fork, and downloads strip resource forks.
write_dmg_settings() {
  cat > "$1" << 'PYTHON'
import os

app = defines["app"]  # noqa: F821 (dmgbuild provides `defines`)
background = defines["background"]  # noqa: F821

format = "UDZO"
filesystem = "APFS"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")

default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
window_rect = ((200, 160), (660, 400))
icon_size = 128
text_size = 13
label_pos = "bottom"
icon_locations = {
    os.path.basename(app): (170, 176),
    "Applications": (490, 176),
}
PYTHON
}

# =============================================================================================
# notarize: Apple's notary service
# =============================================================================================

help_notarize() {
  cat << EOF
Usage: $PROG notarize PATH

Sends an app or a disk image (for example $APP or $DMG) to Apple's notary service and staples
the ticket to it. When no credentials are set, it does nothing and succeeds.

Credentials, either one of:
  IMP_NOTARY_PROFILE   a keychain profile, made once with: xcrun notarytool store-credentials
  IMP_NOTARY_KEY, IMP_NOTARY_KEY_ID and IMP_NOTARY_ISSUER
                       an App Store Connect API key: the path of the .p8 file, its ID and the issuer
EOF
}

cmd_notarize() {
  case "${1:-}" in
    -h | --help) help_notarize; return ;;
    "") usage_error notarize "give the path of an app or a disk image" ;;
  esac
  [[ $# -eq 1 ]] || usage_error notarize "give exactly one path"
  local target="$1"
  [[ -e "$target" ]] || die "$target does not exist"

  local auth=()
  if [[ -n "${IMP_NOTARY_PROFILE:-}" ]]; then
    auth=(--keychain-profile "$IMP_NOTARY_PROFILE")
  elif [[ -n "${IMP_NOTARY_KEY:-}" && -n "${IMP_NOTARY_KEY_ID:-}" && -n "${IMP_NOTARY_ISSUER:-}" ]]; then
    auth=(--key "$IMP_NOTARY_KEY" --key-id "$IMP_NOTARY_KEY_ID" --issuer "$IMP_NOTARY_ISSUER")
  else
    echo "Not notarizing $target (no notary credentials)"
    return
  fi

  # The service takes an archive, not a bundle folder.
  local submit="$target"
  if [[ -d "$target" ]]; then
    scratch
    submit="$WORK/$(basename "$target" .app).zip"
    ditto -c -k --keepParent "$target" "$submit"
  fi

  xcrun notarytool submit "$submit" "${auth[@]}" --wait
  xcrun stapler staple "$target"
  xcrun stapler validate "$target"
  echo "Notarized $target"
}

# =============================================================================================
# cask: the Homebrew cask
# =============================================================================================

help_cask() {
  cat << EOF
Usage: $PROG cask VERSION SHA256

Prints the Homebrew cask of a release. VERSION has no leading v (for example 2.7.3) and SHA256 is
the checksum of Imp.dmg (shasum -a 256 $DMG). The release workflow writes the output to
impsland/homebrew-tap as Casks/imp.rb.
EOF
}

cmd_cask() {
  case "${1:-}" in
    -h | --help) help_cask; return ;;
  esac
  [[ $# -eq 2 ]] || usage_error cask "give a version and a SHA-256 checksum"
  local version="$1" sha256="$2"
  [[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || usage_error cask "$version is not a version like 2.7.3"
  [[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || usage_error cask "$sha256 is not a SHA-256 checksum"

  cat << CASK
cask "imp" do
  version "$version"
  sha256 "$sha256"

  url "https://github.com/impsland/imp/releases/download/v#{version}/Imp.dmg"
  name "Imp"
  desc "Tiny desk imp that answers, talks and runs shell commands for you"
  homepage "https://github.com/impsland/imp"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sequoia

  app "Imp.app"

  # Imp is signed with its own certificate, not notarized by Apple: clear the download quarantine so Gatekeeper lets it open.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/Imp.app"]
  end

  uninstall quit: "app.imp.Imp"

  zap trash: [
    "~/Library/Application Support/Imp",
    "~/Library/Preferences/app.imp.Imp.plist",
  ]
end
CASK
}

# =============================================================================================
# design-images: pictures of the screens for the docs
# =============================================================================================

DESIGN_IMAGES_DIR="docs/ux/images"
DESIGN_SCENES=(
  canvas-empty canvas-imps
  imp-brain imp-sleeping imp-personality imp-look imp-animations imp-triggers imp-tools imp-computer
  imp-look-narrow imp-agent-tools imp-trigger-editor imp-trigger-steps
  all-imps-app all-imps-app-narrow all-imps-nothing
  first-run-service first-run-error
  bar-menu bar-menu-es
  all-imps-pair all-imps-bubble all-imps-talking all-imps-brains devices-empty devices-linked devices-imp devices-device devices-focus devices-local
  all-imps-sharing all-imps-privacy all-imps-backup
  bubble-short bubble-read-all bubble-chat
)

help_design_images() {
  cat << EOF
Usage: $PROG design-images [--list] [SCENE...]

Draws the main screens in their key states with the app's own offscreen renderer and saves them
as $DESIGN_IMAGES_DIR/<scene>.png. Without a scene, it draws them all. Build the core first.

Options:
  --list       print the scene names and stop
  -h, --help   show this help

Environment:
  SWIFT        the Swift driver (default: xcrun swift)
EOF
}

cmd_design_images() {
  local scenes=()
  while (( $# )); do
    case "$1" in
      --list) printf '%s\n' "${DESIGN_SCENES[@]}"; return ;;
      -h | --help) help_design_images; return ;;
      -*) usage_error design-images "unknown option $1" ;;
      *) scenes+=("$1") ;;
    esac
    shift
  done
  if (( ${#scenes[@]} == 0 )); then scenes=("${DESIGN_SCENES[@]}"); fi

  swift_run build --package-path "$PACKAGE" --product Imp
  local bin_dir
  bin_dir="$(swift_run build --package-path "$PACKAGE" --show-bin-path)"

  # The words come from the String Catalogs, so the binary runs inside a throwaway app bundle that
  # has them compiled. A bare `swift build` binary would show the keys instead of the words.
  scratch
  local app="$WORK/Imp.app" bundle
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$bin_dir/Imp" "$app/Contents/MacOS/Imp"
  cp "$INFO_PLIST" "$app/Contents/Info.plist"
  for bundle in "$bin_dir"/*.bundle; do
    if [[ -e "$bundle" ]]; then cp -R "$bundle" "$app/Contents/Resources/"; fi
  done
  compile_catalogs "$app/Contents/Resources"

  mkdir -p "$DESIGN_IMAGES_DIR"
  local scene
  for scene in "${scenes[@]}"; do
    "$app/Contents/MacOS/Imp" --render-home "$scene" "$DESIGN_IMAGES_DIR/$scene.png"
    echo "$DESIGN_IMAGES_DIR/$scene.png"
  done
}

# =============================================================================================
# strings and check-strings: the String Catalogs
# =============================================================================================

help_strings() {
  cat << EOF
Usage: $PROG strings

Syncs $CATALOGS/Localizable.xcstrings with the source. The compiler lists every
localizable string it sees (SwiftUI text, String(localized:) and LocalizedStringResource), then
xcstringstool adds the new keys and marks the removed ones as stale. Translations are kept.

Run it after changing user-facing text, then translate what is new. Build the core first.

Environment:
  SWIFT   the Swift driver (default: xcrun swift)
EOF
}

cmd_strings() {
  case "${1:-}" in
    -h | --help) help_strings; return ;;
    "") ;;
    *) usage_error strings "unexpected argument $1" ;;
  esac
  scratch
  swift_run build --package-path "$PACKAGE" --product Imp --scratch-path apple/.build/strings \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$WORK"
  xcrun xcstringstool sync "$CATALOGS/Localizable.xcstrings" --stringsdata "$WORK"/*.stringsdata
  echo "Synced $CATALOGS/Localizable.xcstrings"
}

help_check_strings() {
  cat << EOF
Usage: $PROG check-strings [FILE.swift...]

Checks that every dotted string key used in Swift code (like "home.title") has English, Spanish
and Simplified Chinese text. A key lives in design/strings/*.json or in
$CATALOGS/Localizable.xcstrings. Without files, it checks every Swift file under apple/.

Exits with status 1 and lists each key that lacks a language.

Needs python3.
EOF
}

cmd_check_strings() {
  case "${1:-}" in
    -h | --help) help_check_strings; return ;;
  esac
  require python3 "Install the Xcode command line tools: xcode-select --install"
  local files=()
  if (( $# )); then
    files=("$@")
  else
    local file
    while IFS= read -r file; do files+=("$file"); done \
      < <(find apple -name '*.swift' -not -path '*/.build/*' | sort)
  fi

  python3 -I - "$CATALOGS/Localizable.xcstrings" "${files[@]}" << 'PYTHON'
import glob
import json
import re
import sys

LANGUAGES = ("en", "es", "zh-Hans")
# Only keys in these areas come from design/strings. Other dotted strings are not text keys.
AREAS = ("settings", "menu", "common", "states", "home", "imps", "phone", "sheets",
         "first-run", "extension", "imp-settings", "all-imps")
KEY = re.compile(r'"([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)"')

catalog_path, swift_files = sys.argv[1], sys.argv[2:]

# The languages each key has text in: design/strings first, then the app's own catalog.
languages_of = {}
for path in glob.glob("design/strings/*.json"):
    with open(path, encoding="utf-8") as file:
        for key, entry in json.load(file).items():
            languages_of[key] = {lang for lang in LANGUAGES if entry.get(lang)}
with open(catalog_path, encoding="utf-8") as file:
    for key, entry in json.load(file)["strings"].items():
        translated = {
            lang for lang, unit in entry.get("localizations", {}).items()
            if unit.get("stringUnit", {}).get("value")
        }
        languages_of.setdefault(key, translated)

problems = 0
for path in swift_files:
    with open(path, encoding="utf-8") as file:
        for number, line in enumerate(file, 1):
            if line.lstrip().startswith("//"):
                continue
            for key in KEY.findall(line):
                if key.split(".")[0] not in AREAS:
                    continue
                missing = [lang for lang in LANGUAGES if lang not in languages_of.get(key, set())]
                if missing:
                    problems += 1
                    print(f"{path}:{number}: {key} lacks {', '.join(missing)}")

files = f"{len(swift_files)} file{'' if len(swift_files) == 1 else 's'}"
print(f"{problems} missing" if problems else f"Every key in {files} has every language.")
sys.exit(1 if problems else 0)
PYTHON
}

# =============================================================================================
# ios and ios-device: the iPhone app
# =============================================================================================

help_ios() {
  cat << EOF
Usage: $PROG ios [--tests]

Writes the iPhone app's Xcode project from apple/iOS/project.yml (XcodeGen) and builds the app
for the Simulator, unsigned. Build the core first ($PROG core).

Options:
  --tests      also build the snapshot tests, without running them (running them needs the
               Simulator, see docs/apps/testing.md)
  -h, --help   show this help

Needs XcodeGen: brew install xcodegen
EOF
}

cmd_ios() {
  local action="build"
  case "${1:-}" in
    --tests) action="build-for-testing" ;;
    -h | --help) help_ios; return ;;
    "") ;;
    *) usage_error ios "unknown argument $1" ;;
  esac
  generate_ios_project
  xcodebuild_filtered -project "$IOS_PROJECT" -scheme ImpPhone \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath apple/.build/ios \
    CODE_SIGNING_ALLOWED=NO -quiet "$action"
  echo "Built the iPhone app for the Simulator ($action)"
}

help_ios_device() {
  cat << EOF
Usage: $PROG ios-device [--device NAME] [--team ID] [--config Release|Debug]

Builds the iPhone app signed, installs it on a connected iPhone (by cable, or over Wi-Fi once
paired in Xcode) and opens it. It also builds the core it needs.

Options:
  --device NAME   the iPhone's name or UDID (default: the only one connected, see
                  xcrun devicectl list devices)
  --team ID       the Apple Developer Team ID to sign with (default: a team signed in to Xcode,
                  else the team of your Apple Development certificate)
  --config NAME   Release (default) or Debug. Debug understands -hatch, -openChat and more,
                  see apple/iOS/README.md.
  -h, --help      show this help

Environment:
  DEVICE, TEAM, CONFIG   the same as the options

Needs XcodeGen (brew install xcodegen), rustup and python3.
EOF
}

cmd_ios_device() {
  local device="${DEVICE:-}" team="${TEAM:-}" config="${CONFIG:-Release}"
  while (( $# )); do
    case "$1" in
      --device) [[ $# -ge 2 ]] || usage_error ios-device "--device needs a value"; device="$2"; shift ;;
      --team) [[ $# -ge 2 ]] || usage_error ios-device "--team needs a value"; team="$2"; shift ;;
      --config) [[ $# -ge 2 ]] || usage_error ios-device "--config needs a value"; config="$2"; shift ;;
      -h | --help) help_ios_device; return ;;
      *) usage_error ios-device "unknown argument $1" ;;
    esac
    shift
  done
  case "$config" in
    Release | Debug) ;;
    *) usage_error ios-device "the configuration is Release or Debug, not $config" ;;
  esac

  # Made here, not inside find_iphone, because $(...) runs in a subshell that would not clean it up.
  scratch
  if [[ -z "$device" ]]; then device="$(find_iphone)"; fi
  if [[ -z "$team" ]]; then team="$(find_team)"; fi

  local derived="apple/.build/ios-device"
  cmd_core --release mac ios
  generate_ios_project
  xcodebuild_filtered -project "$IOS_PROJECT" -scheme ImpPhone -configuration "$config" \
    -destination 'generic/platform=iOS' -derivedDataPath "$derived" \
    DEVELOPMENT_TEAM="$team" -allowProvisioningUpdates -quiet build

  local app="$derived/Build/Products/$config-iphoneos/Imp.app"
  if ! device_attempt "$device" "install Imp" xcrun devicectl device install app --device "$device" "$app"; then
    grep -E "ERROR|error" "$WORK/devicectl.log" | head -3 >&2 || true
    die "couldn't install Imp on $device. Unlock it and keep it awake, or plug it in with a cable, then try again."
  fi
  if ! device_attempt "$device" "open Imp" \
    xcrun devicectl device process launch --device "$device" --terminate-existing app.imp.ImpPhone; then
    echo "Installed. Unlock the iPhone and open Imp. The first time, trust the developer in"
    echo "Settings › General › VPN & Device Management."
  fi
}

# Prints the UDID of the only paired iPhone. With none or several, it lists them and stops.
# Call `scratch` first.
find_iphone() {
  local list="$WORK/devices.json" udid
  xcrun devicectl list devices --quiet --json-output "$list" > /dev/null
  udid="$(python3 -I - "$list" << 'PYTHON'
import json
import sys

with open(sys.argv[1]) as file:
    devices = json.load(file).get("result", {}).get("devices", [])
phones = [
    device for device in devices
    if device.get("hardwareProperties", {}).get("reality") == "physical"
    and device.get("hardwareProperties", {}).get("deviceType") == "iPhone"
    and device.get("connectionProperties", {}).get("pairingState") == "paired"
]
if len(phones) == 1:
    print(phones[0]["hardwareProperties"]["udid"])
else:
    for phone in phones:
        print(f'  {phone["deviceProperties"]["name"]}  {phone["hardwareProperties"]["udid"]}', file=sys.stderr)
PYTHON
)"
  [[ -n "$udid" ]] || die "connect one iPhone and trust this Mac, or pick one with --device NAME (or DEVICE=NAME)"
  echo "$udid"
}

# Prints the Team ID to sign with: a team signed in to Xcode first, since Xcode can make
# provisioning profiles for it, else the team of an Apple Development certificate.
find_team() {
  local team
  team="$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2> /dev/null \
    | awk -F' = ' '/teamID/ { gsub(/[";]/, "", $2); print $2; exit }')" || true
  if [[ -z "$team" ]]; then
    team="$(security find-certificate -c "Apple Development" -p 2> /dev/null \
      | openssl x509 -noout -subject -nameopt multiline 2> /dev/null \
      | awk -F' = ' '/organizationalUnitName/ { print $2; exit }')" || true
  fi
  [[ -n "$team" ]] || die "no Apple Development certificate found. Sign in to Xcode, or pass --team ID (or TEAM=ID)."
  echo "$team"
}

# Runs a devicectl step up to three times. Over Wi-Fi the connection to the iPhone drops when it
# locks or sleeps, and sometimes in the middle of a copy ("Connection reset by peer"), so each try
# wakes the connection first. The output of the last try is in $WORK/devicectl.log.
device_attempt() {
  local device="$1" what="$2" try
  shift 2
  for try in 1 2 3; do
    xcrun devicectl device info details --device "$device" > /dev/null 2>&1 || true
    if "$@" > "$WORK/devicectl.log" 2>&1; then return 0; fi
    if (( try < 3 )); then
      echo "The iPhone didn't answer while trying to $what. Trying again ($((try + 1)) of 3)…" >&2
      sleep 3
    fi
  done
  return 1
}

# =============================================================================================
# help and the entry point
# =============================================================================================

COMMANDS=(core app dmg notarize cask design-images strings check-strings ios ios-device)

help_main() {
  cat << EOF
Usage: $PROG <command> [options] [arguments]

The build tool for the Apple apps. Most people run it through make (run make help).

Mac app:
  core            build the Rust core and its Swift bindings for the apps
  app             build, sign and assemble $APP
  dmg             pack $APP into the installer disk image $DMG
  notarize PATH   send an app or a disk image to Apple's notary service
  cask VERSION SHA256
                  print the Homebrew cask of a release

iPhone app:
  ios             build the iPhone app for the Simulator
  ios-device      build the iPhone app and install it on a connected iPhone

Words and pictures:
  strings         add new user-facing text to the String Catalogs
  check-strings   check that every text key used in Swift has all three languages
  design-images   draw the screen pictures in $DESIGN_IMAGES_DIR

Other:
  help [COMMAND]  show this help, or the help of one command

Run "$PROG <command> --help" for the options of a command.
EOF
}

# Prints the help of one command, or the main help.
show_help() {
  local command="${1:-}"
  if [[ -z "$command" ]]; then
    help_main
  elif declare -F "help_${command//-/_}" > /dev/null && [[ "$command" != main ]]; then
    "help_${command//-/_}"
  else
    echo "error: unknown command $command" >&2
    echo >&2
    help_main >&2
    exit 2
  fi
}

main() {
  local command="${1:-help}"
  if (( $# )); then shift; fi
  case "$command" in
    help | -h | --help) show_help "${1:-}" ;;
    *)
      local known
      for known in "${COMMANDS[@]}"; do
        if [[ "$command" == "$known" ]]; then
          "cmd_${command//-/_}" "$@"
          return
        fi
      done
      show_help "$command"
      ;;
  esac
}

main "$@"
