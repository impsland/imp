# The developer commands for Imp. Run `make` or `make help` to list them.
#
# The Apple steps live in apple/scripts/apple.sh, which has more options than the targets here
# (run apple/scripts/apple.sh help). The design files come from design/generate.mjs.
#
# Variables you can set on the command line, for example `make snapshots RECORD=1`:
#
#   SWIFT     the Swift driver (default: xcrun swift)
#   VERSION   the version that `make dist` stamps into the app (default: the one in Info.plist)
#   RECORD    1 makes `make snapshots` record every snapshot again
#   DEVICE    the iPhone for `make ios-device`, by name or UDID (default: the only one connected)
#   TEAM      the Apple Developer Team ID for `make ios-device` (default: found in Xcode)
#   CONFIG    Release or Debug for `make ios-device` (default: Release)
#   IMP_HOP     the Hop's host:port for `make test-server` (default: this Mac's .local name, port 4677).
#               Not localhost: a linking code never gives out a loopback Hop, see engine/src/link/card.rs.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

APPLE_TOOL := apple/scripts/apple.sh
SWIFT ?= xcrun swift
SWIFT_PACKAGE := --package-path apple
VERSION ?= $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" apple/Resources/Info.plist)
RECORD ?= 0
CONFIG ?= Release
IMP_HOP ?= $(shell scutil --get LocalHostName 2> /dev/null || hostname -s).local:4677

# apple.sh reads SWIFT from the environment.
export SWIFT

# Options for `apple.sh ios-device`, added only when the variable is set.
IOS_DEVICE_OPTIONS := $(strip $(if $(DEVICE),--device "$(DEVICE)") $(if $(TEAM),--team "$(TEAM)") --config "$(CONFIG)")

.PHONY: help core build app run install dist \
	test snapshots test-live test-server \
	ios ios-snapshots-build ios-device \
	strings check-strings design-images tokens tokens-check \
	rust docs web clean

##@ Help

help: ## List the commands
	@awk 'BEGIN { FS = ":.*## " } \
		/^##@ / { printf "\n%s\n", substr($$0, 5) } \
		/^[a-z-]+:.*## / { printf "  make %-21s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo
	@echo "Variables such as RECORD=1 or DEVICE=... are explained at the top of the Makefile."

##@ Mac app

# The core is a Rust library. It goes to apple/Frameworks and its Swift bindings to
# apple/Sources/ImpCore. Both are generated and not committed. It is built for the Mac and the
# iPhone Simulator, so switching between the Mac and the iPhone targets never rebuilds it.
core: ## Build the Rust core for the Mac app and the iPhone Simulator
	$(APPLE_TOOL) core

build: core ## Build the Mac app (debug)
	$(SWIFT) build $(SWIFT_PACKAGE)

app: core ## Build build/Imp.app (release, signed)
	$(APPLE_TOOL) app

run: app ## Build Imp.app and open it
	pkill -x Imp || true # Quit a running Imp first. None running is fine.
	open build/Imp.app

install: app ## Build Imp.app, copy it to /Applications and open it
	pkill -x Imp || true # Quit a running Imp first. None running is fine.
	rm -rf /Applications/Imp.app
	cp -R build/Imp.app /Applications/
	open /Applications/Imp.app

# The installer of a GitHub release: universal (Apple silicon and Intel) and stamped with VERSION.
dist: ## Build the universal, versioned installer build/Imp.dmg [VERSION=...]
	$(APPLE_TOOL) core --release mac-universal
	$(APPLE_TOOL) app --universal --version "$(VERSION)"
	$(APPLE_TOOL) dmg
	shasum -a 256 build/Imp.dmg

##@ Tests

test: core ## Run every test, the screen snapshots included
	$(SWIFT) test $(SWIFT_PACKAGE)

# The snapshots in apple/Tests/ImpSnapshotTests record the ones that are missing and compare the rest.
snapshots: core ## Run only the screen snapshots [RECORD=1 records them all again]
	IMP_SNAPSHOTS_RECORD=$(RECORD) $(SWIFT) test $(SWIFT_PACKAGE) --filter ImpSnapshotTests

# Uses the real API configured in .env: a chat, a thinking model, and an Imp that draws and speaks with its tools.
# A run costs a few cents.
test-live: core ## Run the tests against the real API in .env
	IMP_LIVE_TESTS=1 $(SWIFT) test $(SWIFT_PACKAGE) --filter '\.Live[A-Za-z]*Tests'
	IMP_LIVE_TESTS=1 cargo test -p imp-engine --locked --test live -- --nocapture --test-threads=1

# Runs the Rust tests that link two devices through a Hop that is already running (see server/README.md).
# The Hop tests are in Rust (chat/tests/hop_live.rs). Run the Hop with
# HOP_PER_IP_PER_MINUTE raised, for example 100000, or repeated runs hit its rate limit.
test-server: core ## Run the tests against a running Hop [IMP_HOP=...]
	IMP_HOP="$(IMP_HOP)" cargo test -p imp-chat --locked --test hop_live -- --ignored

##@ iPhone app

# The project in apple/iOS is written by XcodeGen from apple/iOS/project.yml.
ios: core ## Build the iPhone app for the Simulator
	$(APPLE_TOOL) ios

# Running the iPhone snapshots needs the Simulator, see docs/apps/testing.md.
ios-snapshots-build: core ## Build the iPhone snapshot tests without running them
	$(APPLE_TOOL) ios --tests

# Builds the core it needs by itself, signed for a real iPhone.
ios-device: ## Install the iPhone app on your iPhone and open it [DEVICE=... TEAM=... CONFIG=Debug]
	$(APPLE_TOOL) ios-device $(IOS_DEVICE_OPTIONS)

##@ Words and design

# Adds new keys to apple/Resources/Localization/Localizable.xcstrings and marks removed ones as stale.
strings: core ## Add new user-facing text to the String Catalogs, for translation
	$(APPLE_TOOL) strings

check-strings: ## Check that every text key used in Swift has all three languages
	$(APPLE_TOOL) check-strings

# Writes design tokens, components and words for every platform from design/ (needs Node 20 or newer).
tokens: ## Generate the design tokens, components and words of every platform
	node design/generate.mjs

# CI and the ImpDesign tests run this check too.
tokens-check: ## Fail when a generated design file is out of date
	node design/generate.mjs --check

design-images: core ## Draw the screen pictures in docs/ux/images
	$(APPLE_TOOL) design-images

##@ Rust and docs

# The same steps as CI: with every feature, then the core without its default features.
rust: ## Check the format, lint and test the Rust workspace
	cargo fmt --all --check
	cargo clippy --workspace --all-targets --locked -- -D warnings
	cargo test --workspace --locked
	cargo clippy -p imp-engine -p imp-ffi --no-default-features --all-targets --locked -- -D warnings
	cargo test -p imp-engine --no-default-features --locked

web: ## Build the web page's link node into web/app/pkg (see web/README.md)
	web/build.sh

docs: ## Build the documentation site in docs/
	cd docs && npm ci && npm run build

clean: ## Remove the build output
	rm -rf apple/.build build target
