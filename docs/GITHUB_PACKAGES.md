# GitHub Packages

Noise's desktop installation files can also be mirrored to GitHub Packages as
OCI artifacts in GitHub Container Registry (GHCR). GitHub does not offer a generic
DMG, EXE, or Debian package registry. ORAS retrieves the original installation
files from an OCI artifact; installation still happens on the matching OS.

For ordinary installation, the [public Releases page](https://github.com/mvs2403/Noise/releases)
provides direct downloads with no extra retrieval tool.

## Package layout

| Platform | Package name | Release version |
| --- | --- | --- |
| macOS, Apple Silicon | [`ghcr.io/mvs2403/noise-macos-arm64`](https://github.com/mvs2403/Noise/pkgs/container/noise-macos-arm64) | `0.1.0` |
| Windows x64 | [`ghcr.io/mvs2403/noise-windows-x64`](https://github.com/mvs2403/Noise/pkgs/container/noise-windows-x64) | `0.2.0`, `0.3.0` |
| Linux x64 | [`ghcr.io/mvs2403/noise-linux-x64`](https://github.com/mvs2403/Noise/pkgs/container/noise-linux-x64) | `0.3.0` |

These bundles are public and can be pulled without signing into GitHub.
Explicit version tags are recommended for repeatable downloads. The `latest`
alias follows each platform's highest published version, including beta releases.
Backfilling an older release does not move it backward.

Each bundle includes its installers/portable archive, the exact original build
manifest, matching source archive, installation notes, bundle metadata, and
checksums. The Mac package remains ad hoc signed and unnotarized; Windows and
Linux packages remain unsigned betas. Mirroring does not rebuild or re-sign them.

## Retrieve a bundle

Install [ORAS](https://oras.land/docs/installation/), then retrieve the matching
platform bundle into an empty folder. For example:

```sh
oras pull ghcr.io/mvs2403/noise-linux-x64:0.3.0 --output Noise-linux
cd Noise-linux
sha256sum -c SHA256SUMS.txt
sudo apt install ./Noise-0.3.0-linux-x64.deb
```

On macOS use `shasum -a 256 -c SHA256SUMS.txt`. On Windows use
`Get-FileHash -Algorithm SHA256` and compare with the checksum list. Follow the
included `INSTALL.md` and the platform guide for audio routing. A package's
digest can be used instead of its version tag for an immutable reference.

## Publishing and verification

The **Publish GitHub Packages** workflow runs when a release is published, and
can also be dispatched manually with an existing release tag. Upload every
installer, source archive, build manifest, and `SHA256SUMS.txt` before publishing
the release. If assets are added afterward, dispatch the workflow again.

The workflow uses its repository-scoped `GITHUB_TOKEN` with `contents: read` and
`packages: write`; no personal access token is stored. It uses a pinned ORAS
binary, verifies each release asset's GitHub digest and checksum, checks the
build manifest and exact source commit, then publishes one bundle per platform
present in that release. It pulls each bundle back by registry digest and checks
every file. Existing version tags with different files are rejected.

The initial mirrors passed these publication checks:

- [Windows and Linux 0.3.0](https://github.com/mvs2403/Noise/actions/runs/39038759062).
- [Windows 0.2.0](https://github.com/mvs2403/Noise/actions/runs/39038778291).
- [macOS 0.1.0](https://github.com/mvs2403/Noise/actions/runs/39038845676).

First publication may create a private package even for a public repository.
Check Package settings and make it public, then verify an anonymous pull.
The repository association and Actions access are configured through publication
from the repository and its source annotation.

For a local preparation check without publishing:

```sh
python3 script/publish_packages.py --release-tag v0.3.0 \
  --work-dir .cache/packages-check --prepare-only
```

Use a new work directory for each run. Publishing additionally needs ORAS on
`PATH` and an authenticated `--registry-config` file; keep that file outside the
repository. The workflow removes its temporary registry credentials on completion.

## Registry documentation

- [GitHub Packages registry formats](https://docs.github.com/en/packages/learn-github-packages/introduction-to-github-packages).
- [ORAS and GHCR](https://oras.land/docs/compatible_oci_registries/).
- [GitHub package permissions and visibility](https://docs.github.com/en/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility).
