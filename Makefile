SWIFT ?= xcrun swift
VERSION ?= $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)

.PHONY: build app dist run test test-live test-server install clean strings ios ios-device help

build:
	$(SWIFT) build

app:
	SWIFT="$(SWIFT)" ./scripts/build-app.sh

# Universal, version-stamped installer disk image for a GitHub release: build/Imp.dmg
dist:
	SWIFT="$(SWIFT)" ARCHS="arm64 x86_64" VERSION="$(VERSION)" ./scripts/build-app.sh
	./scripts/build-dmg.sh
	shasum -a 256 build/Imp.dmg

run: app
	-pkill -x Imp; open build/Imp.app

test:
	$(SWIFT) test

# Hits the real API configured in .env (costs a cent or two).
test-live:
	IMP_LIVE_TESTS=1 $(SWIFT) test --filter LiveTests

install: app
	-pkill -x Imp
	rm -rf /Applications/Imp.app && cp -R build/Imp.app /Applications/ && open /Applications/Imp.app

# The iPhone app (iOS/): regenerates its Xcode project (XcodeGen) and builds it for the Simulator.
ios:
	cd iOS && xcodegen generate
	xcodebuild -project iOS/ImpPhone.xcodeproj -scheme ImpPhone -destination 'generic/platform=iOS Simulator' \
		-derivedDataPath .build/ios CODE_SIGNING_ALLOWED=NO -quiet build

# Sends the iPhone app to your iPhone: builds it signed, installs it on the connected phone and opens it.
# DEVICE=<name or UDID> picks one of several phones, TEAM=<Team ID> signs with another team, CONFIG=Debug for a debug build.
ios-device:
	./scripts/ios-device.sh

# Adds new user-facing text to the String Catalogs (Resources/Localization) for translation.
strings:
	SWIFT="$(SWIFT)" ./scripts/strings.sh

clean:
	rm -rf .build build

# Plays a Mac, an iPhone and an Imp against a running Den and Hop (see server/README.md).
test-server:
	IMP_SERVER=$${IMP_SERVER:-http://localhost:8080} $(SWIFT) test --filter ServerLiveTests

# Lists the commands.
help:
	@echo "make              build the Mac app (debug)"
	@echo "make app          Imp.app in build/"
	@echo "make run          build and open Imp.app"
	@echo "make install      build and install to /Applications"
	@echo "make dist         universal, versioned build/Imp.dmg"
	@echo "make test         run the tests"
	@echo "make test-live    tests against the real API in .env"
	@echo "make test-server  tests against a running Den and Hop"
	@echo "make ios          build the iPhone app for the Simulator"
	@echo "make ios-device   send the iPhone app to your iPhone [DEVICE=… TEAM=… CONFIG=Debug]"
	@echo "make strings      add new text to the String Catalogs"
	@echo "make clean        remove .build and build"
