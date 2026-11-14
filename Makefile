SWIFT ?= xcrun swift
APPLE := --package-path apple
VERSION ?= $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" apple/Resources/Info.plist)

CORE := ./apple/scripts/core.sh

.PHONY: core build app dist run test snapshots design-images test-live test-server install clean strings tokens tokens-check ios ios-snapshots-build ios-device rust docs help

# The portable core for the Mac and the iPhone Simulator (apple/Frameworks and apple/Sources/ImpCore, both generated).
core:
	$(CORE)

build: core
	$(SWIFT) build $(APPLE)

app: core
	SWIFT="$(SWIFT)" ./apple/scripts/build-app.sh

# Universal, version-stamped installer disk image for a GitHub release: build/Imp.dmg
dist:
	CORE_PROFILE=release $(CORE) mac-universal
	SWIFT="$(SWIFT)" ARCHS="arm64 x86_64" VERSION="$(VERSION)" ./apple/scripts/build-app.sh
	./apple/scripts/build-dmg.sh
	shasum -a 256 build/Imp.dmg

run: app
	-pkill -x Imp; open build/Imp.app

# Every test, the screen snapshots (apple/Tests/ImpSnapshotTests) included.
test: core
	$(SWIFT) test $(APPLE)

# Only the screen snapshots. They record what is missing, and compare the rest. RECORD=1 records them all again.
snapshots: core
	IMP_SNAPSHOTS_RECORD=$(if $(RECORD),1,0) $(SWIFT) test $(APPLE) --filter ImpSnapshotTests

# The pictures of the main screens in docs/ux/images, drawn by the app's offscreen renderer.
design-images: core
	SWIFT="$(SWIFT)" ./apple/scripts/design-images.sh

# Hits the real API configured in .env: chat, tools, recaps, and pictures and speech through MCP (costs a few cents).
test-live: core
	IMP_LIVE_TESTS=1 $(SWIFT) test $(APPLE) --filter '\.Live[A-Za-z]*Tests'
	IMP_LIVE_TESTS=1 cargo test -p imp-core --locked --test live -- --nocapture --test-threads=1

install: app
	-pkill -x Imp
	rm -rf /Applications/Imp.app && cp -R build/Imp.app /Applications/ && open /Applications/Imp.app

# The iPhone app (apple/iOS/): regenerates its Xcode project (XcodeGen) and builds it for the Simulator.
# Xcode's note that the placeholder device has no iOS version is noise, so that one line is dropped.
ios: core
	cd apple/iOS && xcodegen generate
	set -o pipefail; xcodebuild -project apple/iOS/ImpPhone.xcodeproj -scheme ImpPhone -destination 'generic/platform=iOS Simulator' \
		-derivedDataPath apple/.build/ios CODE_SIGNING_ALLOWED=NO -quiet build 2>&1 \
		| { grep -v 'IDESchemeActionsInvocationRecord' || true; }

# Builds the iPhone's snapshot tests without running them (running them needs the Simulator, see docs/apps/testing.md).
ios-snapshots-build: core
	cd apple/iOS && xcodegen generate
	set -o pipefail; xcodebuild -project apple/iOS/ImpPhone.xcodeproj -scheme ImpPhone -destination 'generic/platform=iOS Simulator' \
		-derivedDataPath apple/.build/ios CODE_SIGNING_ALLOWED=NO -quiet build-for-testing 2>&1 \
		| { grep -v 'IDESchemeActionsInvocationRecord' || true; }

# Sends the iPhone app to your iPhone: builds it signed, installs it on the connected phone and opens it.
# DEVICE=<name or UDID> picks one of several phones, TEAM=<Team ID> signs with another team, CONFIG=Debug for a debug build.
ios-device:
	./apple/scripts/ios-device.sh

# Adds new user-facing text to the String Catalogs (apple/Resources/Localization) for translation.
strings: core
	SWIFT="$(SWIFT)" ./apple/scripts/strings.sh

# The Rust workspace (core, cli, server): format, lint and test, as CI runs them.
rust:
	cargo fmt --all --check
	cargo clippy --workspace --all-targets --locked -- -D warnings
	cargo test --workspace --locked
	cargo clippy -p imp-core -p imp-ffi --no-default-features --all-targets --locked -- -D warnings
	cargo test -p imp-core --no-default-features --locked

# The documentation site (docs/).
docs:
	cd docs && npm ci && npm run build

clean:
	rm -rf apple/.build build target

# Plays a Mac, an iPhone and an Imp against a running Den and Hop (see server/README.md).
# IMP_SERVER: the Den's URL (default http://localhost:8080). IMP_HOP: the Hop's host:port (default localhost:4677).
test-server: core
	IMP_SERVER=$${IMP_SERVER:-http://localhost:8080} IMP_HOP=$${IMP_HOP:-localhost:4677} $(SWIFT) test $(APPLE) --filter 'ServerLiveTests|HopLiveTests'

# Writes the design tokens and the user-facing words for every platform from design/ (Node).
tokens:
	node design/generate.mjs

# Fails when a generated design file is out of date (CI and the ImpDesign tests run this).
tokens-check:
	node design/generate.mjs --check

# Lists the commands.
help:
	@echo "make build        build the Mac app (debug)"
	@echo "make core         build the Rust core for the Mac app and the Simulator"
	@echo "make app          Imp.app in build/"
	@echo "make run          build and open Imp.app"
	@echo "make install      build and install to /Applications"
	@echo "make dist         universal, versioned build/Imp.dmg"
	@echo "make test         run the tests (the screen snapshots too)"
	@echo "make snapshots    only the screen snapshots [RECORD=1 to record them again]"
	@echo "make design-images  draw the screen pictures in docs/ux/images"
	@echo "make test-live    tests against the real API in .env"
	@echo "make test-server  tests against a running Den and Hop"
	@echo "make ios          build the iPhone app for the Simulator"
	@echo "make ios-snapshots-build  build the iPhone snapshot tests (no Simulator run)"
	@echo "make ios-device   send the iPhone app to your iPhone [DEVICE=… TEAM=… CONFIG=Debug]"
	@echo "make strings      add new text to the String Catalogs"
	@echo "make tokens       generate the design tokens, components and words of every platform"
	@echo "make tokens-check  fail when a generated design file is out of date"
	@echo "make rust         format check, lint and test the Rust workspace"
	@echo "make docs         build the documentation site"
	@echo "make clean        remove the build output"
