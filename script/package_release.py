#!/usr/bin/env python3
"""Build a private-beta DMG/ZIP, matching source archive, and SHA-256 manifest."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True, **kwargs)


def read(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    version = (ROOT / "VERSION").read_text().strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise SystemExit("VERSION must contain a three-part release version.")
    commit = read("git", "rev-parse", "HEAD")
    if read("git", "status", "--porcelain"):
        raise SystemExit("Commit the release sources, documentation and screenshots before packaging.")
    destination = ROOT / "dist/releases" / version
    destination.mkdir(parents=True, exist_ok=True)
    (ROOT / ".cache").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="release-", dir=ROOT / ".cache") as temporary:
        staging = Path(temporary)
        app = staging / "Noise.app"
        env = dict(os.environ, NOISE_BUILD_CONFIGURATION="release", NOISE_APP_BUNDLE_PATH=str(app))
        run(ROOT / "script/build_and_run.sh", "--build-only", env=env)
        run("python3", ROOT / "script/validate_bundle.py", app)
        products = read("swift", "build", "--configuration", "release", "--show-bin-path")
        run(Path(products) / "NoiseCheck", "verify-bundle", app)

        base = f"Noise-{version}-apple-silicon"
        archive = destination / f"{base}.zip"
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive)
        (staging / "Applications").symlink_to("/Applications")
        (staging / "START HERE.txt").write_text(
            f"Noise {version} · Private beta\n\n"
            "Apple Silicon Mac · macOS 14.2 or later\n\n"
            "1. Drag Noise.app to Applications.\n"
            "2. Open Noise from Applications, then use its waveform icon in the menu bar.\n"
            "3. Select the apps to filter in the Speaker tab and turn Noise cancellation on.\n\n"
            "This beta is locally signed and is not notarized. If macOS blocks it, read Apple's per-app Open Anyway instructions:\n"
            "https://support.apple.com/102445\n\n"
            "Incoming audio works without an extra driver. To filter your microphone too, open Noise Settings and choose Set Up Virtual Microphone. "
            "That optional step requires administrator access and briefly restarts audio. Set it up before a call.\n\n"
            "Setup, limitations, source, and third-party notices:\n"
            "https://github.com/mvs2403/Noise\n"
        )
        image = destination / f"{base}.dmg"
        run("hdiutil", "create", "-volname", f"Noise {version}", "-srcfolder", staging,
            "-format", "UDZO", "-ov", image)
        run("hdiutil", "verify", image)

    source = destination / f"Noise-{version}-source.tar.gz"
    run("git", "archive", "--format=tar.gz", f"--prefix=Noise-{version}/", "-o", source, commit)
    assets = [archive, image, source]
    manifest = destination / "release-manifest.json"
    manifest.write_text(json.dumps({
        "name": "Noise", "version": version, "commit": commit,
        "configuration": "release", "architecture": "arm64", "minimumMacOS": "14.2",
        "signing": "ad-hoc", "notarized": False, "channel": "private-beta",
        "assets": [{"file": path.name, "bytes": path.stat().st_size, "sha256": digest(path)} for path in assets],
    }, indent=2) + "\n")
    checksums = destination / "SHA256SUMS.txt"
    checksums.write_text("".join(f"{digest(path)}  {path.name}\n" for path in [*assets, manifest]))
    print(f"Release assets: {destination}")


if __name__ == "__main__":
    main()
