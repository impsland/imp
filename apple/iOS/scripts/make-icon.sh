#!/bin/sh
# Renders the iPhone app's icon with the Mac app's own icon art (the same tile and Imp, full bleed
# and opaque: iOS rounds the corners itself) into the asset catalog.
set -eu
cd "$(dirname "$0")/../../.."
xcrun swift build --product Imp >/dev/null
apple/.build/debug/Imp --render-ios-icon apple/iOS/Imp/Assets.xcassets/AppIcon.appiconset/AppIcon.png
echo "wrote apple/iOS/Imp/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
