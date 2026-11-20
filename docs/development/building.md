# Building from source

All commands run from the repository root. `make help` lists every target, and `make` on its own does the same.

The Apple targets call `apple/scripts/apple.sh`, the build tool for the Mac and iPhone apps. You can run it
directly for options the targets don't expose, for example `apple/scripts/apple.sh app --debug` or
`apple/scripts/apple.sh design-images bar-menu`. `apple/scripts/apple.sh help` lists its commands, and
`apple/scripts/apple.sh <command> --help` explains one.

## The Mac app

| Command        | What it does                                                                 |
| -------------- | ---------------------------------------------------------------------------- |
| `make app`     | Builds `build/Imp.app` (release, signed)                                     |
| `make run`     | Quits a running Imp, builds `build/Imp.app` and opens it                     |
| `make install` | Builds `build/Imp.app`, copies it to `/Applications` and opens it            |
| `make dist`    | Builds the universal, versioned installer `build/Imp.dmg` for a release (`VERSION=...` sets the version) |

### Dependencies

The Mac app uses one third-party Swift package, [SwiftFlow](https://github.com/aaurelions/SwiftFlow), for the Devices canvas. It is pinned in `apple/Package.swift` and `apple/Package.resolved` and fetched by SwiftPM on the first build. It is MIT licensed. Its notice is in `THIRD_PARTY_NOTICES.md`, which `make app` copies into `Imp.app/Contents/Resources`.

## The iPhone app

| Command                    | What it does                                                                        |
| -------------------------- | ----------------------------------------------------------------------------------- |
| `make ios`                 | Regenerates `apple/iOS/ImpPhone.xcodeproj` with XcodeGen and builds for the Simulator |
| `make ios-device`          | Signs, installs and opens the app on your connected iPhone                          |

`make ios` and `make ios-device` read these variables:

| Variable | Used by         | Meaning                                                      |
| -------- | --------------- | ------------------------------------------------------------ |
| `DEVICE` | `make ios-device` | The iPhone's name or UDID (default: the only one connected) |
| `TEAM`   | `make ios-device` | The Apple Developer Team ID to sign with (default: found in Xcode) |
| `CONFIG` | `make ios-device` | `Release` (default) or `Debug`                               |

The iPhone project needs XcodeGen (`brew install xcodegen`). The phone needs iOS 18 or later.

To install on a phone by hand:

1. Open `apple/iOS/ImpPhone.xcodeproj` in Xcode.
2. Select the `ImpPhone` target, then **Signing & Capabilities**.
3. Choose your team. The project ships with an empty `DEVELOPMENT_TEAM`.

The iPhone app shares `ImpKit`, `ImpDesign` and the Imp renderer with the Mac.

## Text and design

| Command              | What it does                                                                           |
| -------------------- | -------------------------------------------------------------------------------------- |
| `make strings`       | Adds new text to the String Catalog (`apple/Resources/Localization/Localizable.xcstrings`) |
| `make check-strings` | Checks that every text key used in Swift has English, Spanish and Chinese text         |
| `make tokens`        | Generates design tokens, components and words for every platform from `design/` (needs Node 20 or newer) |
| `make tokens-check`  | Fails when a generated design file is out of date                                      |
| `make design-images` | Draws the screen pictures in `docs/ux/images`                                          |

After changing any text in the app, run `make strings`, then translate the new entries in Xcode or any `.xcstrings`
editor. `make app` compiles the catalogs into the app.

## The documentation site

```sh
make docs     # runs npm ci and npm run build in docs/
```

## Where things are

See [Architecture](/architecture/) for the repository layout and the rule that each piece of code belongs to one layer.

## Clean up

```sh
make clean    # removes apple/.build, build and target
```
