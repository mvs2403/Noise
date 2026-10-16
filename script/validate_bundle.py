#!/usr/bin/env python3
"""Validate a self-contained Apple Silicon Noise.app without capturing audio."""
from pathlib import Path
import plistlib
import re
import subprocess
import sys


def output(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def validate(app):
    app = app.resolve()
    contents = app / "Contents"
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    assert info["CFBundleIdentifier"] == "za.co.mvs.Noise", "Unexpected app identifier"
    assert info.get("LSUIElement") is True, "The app must launch as a menu-bar utility"
    resources = contents / "Resources"
    required = [
        "Runtime/libdf.dylib", "Runtime/librnnoise.dylib",
        "Runtime/libweya_nc.dylib", "Runtime/libsherpa-onnx-c-api.dylib",
        "Runtime/libonnxruntime.dylib", "Models/dpdfnet2_48khz_hr.onnx",
        "Models/DeepFilterNet3_onnx.tar.gz", "Models/hush-main-speaker.tar.gz",
        "NoiseMicrophone.driver/Contents/MacOS/NoiseMicrophone",
        "NoiseMicrophone.driver/Contents/Resources/LICENSE-GPL-3.0",
        "THIRD_PARTY_NOTICES.md", "install_microphone.sh", "uninstall_microphone.sh",
    ]
    for relative in required:
        path = resources / relative
        assert path.is_file() and path.stat().st_size > 0, f"Missing: {relative}"
    assert list((resources / "Licenses").glob("*")), "Missing third-party licenses"
    output("codesign", "--verify", "--deep", "--strict", str(app))
    minimum = tuple(map(int, info["LSMinimumSystemVersion"].split(".")))
    binaries = [contents / "MacOS/Noise", resources / "NoiseMicrophone.driver/Contents/MacOS/NoiseMicrophone"]
    binaries += list((resources / "Runtime").glob("*.dylib"))
    for binary in binaries:
        assert "arm64" in output("lipo", "-archs", str(binary)).split(), f"Missing arm64: {binary.name}"
        build = output("xcrun", "vtool", "-show-build", str(binary))
        versions = re.findall(r"\bminos\s+(\d+(?:\.\d+)+)", build)
        assert versions, f"No deployment target: {binary.name}"
        for version in versions:
            actual = tuple(map(int, version.split(".")))
            assert actual <= minimum, f"{binary.name} requires macOS {version}, above the app's {info['LSMinimumSystemVersion']}"
        for line in output("otool", "-L", str(binary)).splitlines()[1:]:
            dependency = line.strip().split(" (")[0]
            if dependency.startswith(("/System/Library/", "/usr/lib/", "@rpath/libswift")):
                continue
            if dependency.startswith("@loader_path/"):
                assert (binary.parent / dependency.removeprefix("@loader_path/")).exists(), f"Missing dependency: {dependency}"
                continue
            raise AssertionError(f"Nonportable dependency in {binary.name}: {dependency}")
    print(f"Validated Noise {info['CFBundleShortVersionString']}: arm64, macOS {info['LSMinimumSystemVersion']}+, valid signatures, bundled runtimes/models/driver.")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: validate_bundle.py /path/to/Noise.app")
    try:
        validate(Path(sys.argv[1]))
    except (AssertionError, KeyError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Bundle validation failed: {error}")
