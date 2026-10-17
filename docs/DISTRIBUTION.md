# Distribution

Noise 0.1.0 is an **Apple Silicon beta**, distributed through
[GitHub Releases](https://github.com/mvs2403/Noise/releases). It includes the app,
all models/runtimes, and the optional Noise Microphone driver. Installing the app
does not require developer tools or an internet connection to download models.

## Install

1. Download `Noise-0.1.0-apple-silicon.dmg` from the public release.
2. Open the disk image and drag **Noise.app** to **Applications**.
3. Eject the disk image and open Noise from Applications. Its waveform menu-bar
   icon remains available after closing the main window.

The ZIP contains the same app as a fallback. Extract it and move Noise.app to
Applications.

This beta has **ad hoc signatures and no Apple notarization ticket**. macOS may
block its first launch. After trying to open it, follow Apple's per-app
[Open Anyway instructions](https://support.apple.com/102445) under
**System Settings → Privacy & Security**, if macOS offers that option. A managed
Mac may require an administrator-approved distribution build.

Incoming filtering works without an extra driver. For outgoing filtering, open
**Noise Settings → Outgoing microphone → Set Up Virtual Microphone**. That step
asks for administrator access and restarts the audio service briefly. Install
before joining a call; then select **Noise Microphone** in the call app.

## Release files

| File | Purpose |
| --- | --- |
| `Noise-VERSION-apple-silicon.dmg` | Drag-and-drop app installation |
| `Noise-VERSION-apple-silicon.zip` | The same application, compressed |
| `Noise-VERSION-source.tar.gz` | Matching source, including the GPL driver source and build scripts |
| `release-manifest.json` | Version, commit, platform, signing state, sizes and hashes |
| `SHA256SUMS.txt` | SHA-256 hashes of the other four files |

To check a downloaded DMG, run `shasum -a 256` on it and compare the result with
its line in `SHA256SUMS.txt`. If you downloaded all assets, run this in their folder:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

The repository and published releases are public. Downloading release packages
does not require a GitHub account. Repository visibility does not change the
packages' signing status or the third-party components' licenses.

The [GitHub Packages workflow](GITHUB_PACKAGES.md) can mirror existing published
installers as OCI artifact bundles, with original build manifests, source, and
checksums. It verifies registry downloads without rebuilding the applications.

## Build a release

On an Apple Silicon Mac with Xcode, Swift 6+, and Python 3.12+:

```sh
python3 script/bootstrap.py
swift test
# Commit the exact source and documentation to be released first.
python3 script/package_release.py
```

The packaging script requires a clean checkout. It reads `VERSION`, builds an
optimized app in a separate temporary staging directory, validates architecture,
deployment targets, nested signatures and dependencies, then loads and streams
all four engines from the packaged resources. It creates and verifies the DMG,
archives the exact Git commit, and writes checksums under `dist/releases/VERSION/`.
It does not install the audio driver or modify system audio devices.

`build_and_run.sh` also accepts `NOISE_BUILD_CONFIGURATION=release` and an absolute
`NOISE_APP_BUNDLE_PATH` for independent staging. Ordinary development runs keep
using `./script/build_and_run.sh`.

The [example GitHub Actions workflow](examples/build-release-workflow.yml) repeats
this process on an Apple Silicon runner and uploads workflow artifacts.
To enable it, copy it into `.github/workflows/build.yml` using GitHub credentials
that can manage workflows. It runs only when dispatched and does not publish or
replace a GitHub Release. It is supplied as an example because the credentials
used for this initial publication do not have the OAuth `workflow` scope.

## Signed distribution

The current build scripts intentionally produce ad hoc beta builds. A production
distribution needs a **Developer ID Application** certificate, hardened runtime,
secure timestamps, correctly signed nested libraries/driver, and successful
Apple notarization before release. An **Apple Development** certificate does not
meet those distribution requirements. See Apple's
[notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

When those credentials are available, update and verify the signing pipeline,
notarize with `notarytool`, staple the accepted ticket, regenerate the DMG/ZIP and
checksums, and validate Gatekeeper on another Mac. Do not label the current
artifacts as notarized.

Preserve [third-party notices](../THIRD_PARTY_NOTICES.md), bundled license texts,
and the matching Noise Microphone source/build instructions with distributions.
