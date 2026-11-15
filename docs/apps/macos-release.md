# Releasing the Mac app

This page is for people who build and publish Imp for the Mac. It says how a release is signed today and how
signing with an Apple Developer ID and notarization turn on later.

## How it works today

- `make dist` builds a universal `build/Imp.dmg`. The release workflow signs the app with a self-signed
  certificate named "Imp Release Signing" (`IMP_SIGN_IDENTITY`), so macOS sees every update as the same app.
  The certificate comes from the `IMP_SIGNING_P12` and `IMP_SIGNING_PASSWORD` secrets. Keychain access and the
  Microphone permission carry over. A local build uses the first "Apple Development" identity it finds, or an
  ad hoc signature.
- Apple has not notarized the app. The Homebrew cask clears the download quarantine (`apple/scripts/apple.sh cask`).
  A person who downloads the disk image by hand follows the guide in
  [Getting started](/guide/getting-started) to open an unsigned app.

## Turning on a Developer ID and notarization

The build tool, `apple/scripts/apple.sh`, is ready. These variables change nothing until the credentials exist.

| Variable | What it does |
| --- | --- |
| `IMP_DEVELOPER_ID` | The name of a "Developer ID Application" certificate in the keychain. `apple.sh app` signs the app with it, with a secure timestamp, and `apple.sh dmg` signs the disk image too. |
| `IMP_NOTARY_PROFILE` | A keychain profile made once with `xcrun notarytool store-credentials`. |
| `IMP_NOTARY_KEY`, `IMP_NOTARY_KEY_ID`, `IMP_NOTARY_ISSUER` | An App Store Connect API key, the other way to give `notarytool` its credentials. |

To turn it on:

1. Install a "Developer ID Application" certificate in the keychain.
2. Give `notarytool` its credentials, with either a keychain profile (`xcrun notarytool store-credentials`) or
   an App Store Connect API key (`IMP_NOTARY_KEY`, `IMP_NOTARY_KEY_ID` and `IMP_NOTARY_ISSUER`).
3. Set `IMP_DEVELOPER_ID` and the notary variables, then run `make dist`.

With `IMP_DEVELOPER_ID` and one of the notary options set, `apple.sh dmg` notarizes twice. It notarizes and
staples the app, packs the disk image, signs it, then notarizes and staples the image. Without notary
credentials, the notarize step (`apple.sh notarize`) prints a line and does nothing. Nothing in the repository
runs these steps until someone sets the variables.

In the release workflow, store the Developer ID certificate and the notary credentials as secrets, and pass them
to the build as these variables.

## What the change that turns it on removes

Once a release is notarized, the pieces for unsigned apps go in the same change:

- The quarantine step in the cask (`cmd_cask` in `apple/scripts/apple.sh`).
- The guide for opening an unsigned app in [Getting started](/guide/getting-started) and its picture
  (`docs/assets/how-to-open-an-unsigned-app-on-macos.svg`).
- The self-signed certificate secrets (`IMP_SIGNING_P12` and `IMP_SIGNING_PASSWORD`) in the release workflow.

Keychain and Microphone grants are tied to the signature. The first notarized update uses a new signature, so
people see those prompts once more. Say so in the release notes.

## Updates

Decision: add Sparkle 2 together with notarization, not before.

- Sparkle checks updates with an EdDSA key, and that works for an unsigned app.
- An unsigned, un-notarized update still shows Gatekeeper warnings and needs the quarantine cleared by hand.
  The experience is poor, so an updater alone gives little.
- Doing both in one change means one move of the signature, one set of release notes and one update feed,
  made once and tested once.
- Until then, `brew upgrade --cask imp` and a new download are the way to update.

Sparkle is not part of the app yet, and no update feed is published.
