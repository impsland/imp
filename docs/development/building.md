# Building from source

All commands run from the repository root. `make help` lists every target.

The Apple targets call `apple/scripts/apple.sh`, the build tool for the Mac and iPhone apps. You can run it
directly for options the targets don't expose, for example `apple/scripts/apple.sh app --debug` or
`apple/scripts/apple.sh design-images bar-menu`. `apple/scripts/apple.sh help` lists its commands, and
`apple/scripts/apple.sh <command> --help` explains one.

## The Mac app

| Command        | What it does                                                    |
| -------------- | --------------------------------------------------------------- |
| `make app`     | Builds `build/Imp.app`                                          |
| `make run`     | Builds and opens `build/Imp.app`                                |
| `make install` | Builds and copies `Imp.app` to `/Applications`                  |
| `make dist`    | Universal, version-stamped installer `build/Imp.dmg` for a release |

## The iPhone app

| Command                              | What it does                                                 |
| ------------------------------------ | ------------------------------------------------------------ |
| `make ios`                           | Regenerates `apple/iOS/ImpPhone.xcodeproj` (XcodeGen) and builds for the Simulator |
| `make ios-device`                    | Signs, installs and opens the app on your connected iPhone. Options: `DEVICE=<name or UDID>`, `TEAM=<Team ID>`, `CONFIG=Debug` |

To install on a phone by hand, open the project in Xcode, select the `ImpPhone` target › **Signing & Capabilities**,
and choose your team. The project ships with an empty `DEVELOPMENT_TEAM`. The phone needs iOS 18 or later.

The iPhone app shares `ImpKit`, `ImpDesign` and the Imp renderer with the Mac.

## Text and design

| Command          | What it does                                                                           |
| ---------------- | -------------------------------------------------------------------------------------- |
| `make strings`   | Adds new text to the String Catalog (`apple/Resources/Localization/Localizable.xcstrings`) |
| `make tokens`    | Generates design tokens, components and words for every platform from `design/`        |
| `make tokens-check` | Fails when a generated design file is out of date                                    |
| `make check-strings` | Checks that every text key used in Swift has English, Spanish and Chinese text     |
| `make design-images` | Draws the screen pictures in `docs/ux/images`                                      |

After changing any text in the app, run `make strings`, then translate the new entries in Xcode or any `.xcstrings` editor.
`make app` compiles the catalogs into the app.

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
