#!/usr/bin/env python3
import argparse
from pathlib import Path
import shutil
import subprocess
import tarfile


def main():
    parser = argparse.ArgumentParser(); parser.add_argument("--stage", type=Path, required=True); parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(); root = Path(__file__).resolve().parent.parent
    version = (root / "VERSION").read_text().strip()
    with tarfile.open(args.output / f"Noise-{version}-linux-x64.tar.gz", "w:gz") as tf:
        tf.add(args.stage, arcname=f"Noise-{version}")
    package = root / ".cache/linux-deb"
    if package.exists(): shutil.rmtree(package)
    (package / "DEBIAN").mkdir(parents=True)
    shutil.copytree(args.stage, package / "opt/noise", symlinks=True)
    desktop = package / "usr/share/applications"; desktop.mkdir(parents=True)
    (desktop / "noise.desktop").write_text("[Desktop Entry]\nType=Application\nName=Noise\nComment=Local noise cancellation for calls\nExec=/opt/noise/Noise\nIcon=noise\nTerminal=false\nCategories=AudioVideo;Audio;\n")
    icons = package / "usr/share/icons/hicolor/1024x1024/apps"; icons.mkdir(parents=True)
    shutil.copy2(root / "docs/images/noise-icon.png", icons / "noise.png")
    (package / "DEBIAN/control").write_text(f"""Package: noise-audio
Version: {version}
Section: sound
Priority: optional
Architecture: amd64
Maintainer: Marco van Staden
Depends: libc6 (>= 2.39), libstdc++6 (>= 13), libpulse0, pulseaudio-utils, libx11-6, libice6, libsm6, libxkbcommon0, libxext6, libxrandr2, libxcursor1, libxi6, libxrender1, libgl1, libfontconfig1, libfreetype6, libicu74 | libicu76 | libicu78, libssl3t64 | libssl3, zlib1g
Recommends: xdotool, libglib2.0-bin
Description: Local noise cancellation for incoming applications and microphones
 DPDFNet, DeepFilterNet3, RNNoise and automatic main-speaker enhancement.
 Requires an existing PulseAudio or PipeWire-Pulse user audio server.
""")
    subprocess.run(["dpkg-deb", "--root-owner-group", "--build", str(package), str(args.output / f"Noise-{version}-linux-x64.deb")], check=True)


if __name__ == "__main__": main()
