#!/usr/bin/env bash
# Prints the Homebrew cask for a release: scripts/cask.sh <version> <sha256 of Imp-<version>.zip>
# Attached to each GitHub release as imp.rb; impsland/homebrew-tap copies it to Casks/imp.rb.
set -euo pipefail
VERSION="$1"
SHA256="$2"

cat <<CASK
cask "imp" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/impsland/imp/releases/download/v#{version}/Imp-#{version}.zip"
  name "Imp"
  desc "Tiny desk imp that answers, talks and runs shell commands for you"
  homepage "https://github.com/impsland/imp"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "Imp.app"

  # Imp is ad-hoc signed, not notarized: clear the download quarantine so Gatekeeper lets it open.
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
