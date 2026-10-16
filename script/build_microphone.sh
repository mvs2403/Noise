#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVER="${1:-$ROOT_DIR/dist/NoiseMicrophone.driver}"
mkdir -p "$DRIVER/Contents/MacOS" "$DRIVER/Contents/Resources"
xcrun clang -bundle -O2 -Wno-format-extra-args -mmacosx-version-min=14.2 \
  '-DkDriver_Name="Noise Microphone"' '-DkDevice_Name="Noise Microphone"' \
  '-DkPlugIn_BundleID="za.co.mvs.Noise.Microphone"' \
  '-DkPlugIn_Icon="NoiseMicrophone.icns"' \
  -DkHas_Driver_Name_Format=false -DkNumber_Of_Channels=2 \
  -DkEnableVolumeControl=false \
  "$ROOT_DIR/Vendor/BlackHole/BlackHole.c" \
  -framework CoreAudio -framework CoreFoundation -framework Accelerate \
  -o "$DRIVER/Contents/MacOS/NoiseMicrophone"
python3 - "$ROOT_DIR" "$DRIVER" <<'PY'
from pathlib import Path
import plistlib, sys
root, driver = map(Path, sys.argv[1:])
info = plistlib.loads((root / "Vendor/BlackHole/Info.plist").read_bytes())
info.update({"CFBundleExecutable": "NoiseMicrophone", "CFBundleIdentifier": "za.co.mvs.Noise.Microphone",
             "CFBundleName": "Noise Microphone", "CFBundleShortVersionString": (root / "VERSION").read_text().strip(),
             "CFBundleVersion": "1"})
factory = "A4AEBA81-5C59-46EB-AE3B-2CB650601D5C"
info["CFPlugInFactories"] = {factory: "BlackHole_Create"}
info["CFPlugInTypes"] = {"443ABAB8-E7B3-491A-B985-BEB9187030DB": [factory]}
(driver / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
PY
cp "$ROOT_DIR/Vendor/BlackHole/LICENSE" "$DRIVER/Contents/Resources/LICENSE-GPL-3.0"
/usr/bin/codesign --force --sign - "$DRIVER" >/dev/null
