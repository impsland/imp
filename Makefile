SWIFT ?= xcrun swift
VERSION ?= $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)

.PHONY: build app dist run test test-live install clean

build:
	$(SWIFT) build

app:
	SWIFT="$(SWIFT)" ./scripts/build-app.sh

# Universal, version-stamped build zipped for a GitHub release: build/Imp-<version>.zip
dist:
	SWIFT="$(SWIFT)" ARCHS="arm64 x86_64" VERSION="$(VERSION)" ./scripts/build-app.sh
	ditto -c -k --keepParent build/Imp.app build/Imp-$(VERSION).zip
	shasum -a 256 build/Imp-$(VERSION).zip

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

clean:
	rm -rf .build build
