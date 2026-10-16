#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
APP_NAME="Noise"
BUNDLE_ID="za.co.mvs.Noise"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
CONFIGURATION="${NOISE_BUILD_CONFIGURATION:-debug}"
case "$CONFIGURATION" in debug|release) ;; *) echo "NOISE_BUILD_CONFIGURATION must be debug or release." >&2; exit 2 ;; esac
case "$MODE" in
  run|--build-only|--debug|--logs|--telemetry|--verify) ;;
  *) echo "usage: $0 [run|--build-only|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac

# Only stop the app staged by this workspace, never an unrelated app named Noise.
APP_BUNDLE="${NOISE_APP_BUNDLE_PATH:-$ROOT_DIR/dist/$APP_NAME.app}"
if [[ "$APP_BUNDLE" != /* ]]; then echo "NOISE_APP_BUNDLE_PATH must be absolute." >&2; exit 2; fi
if [[ -f "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ]]; then
  /usr/bin/pkill -f "^$APP_BUNDLE/Contents/MacOS/$APP_NAME" >/dev/null 2>&1 || true
fi
mkdir -p .cache
python3 script/bootstrap.py
swift build --configuration "$CONFIGURATION"
BUILD_DIR="$(swift build --configuration "$CONFIGURATION" --show-bin-path)"
CONTENTS="$APP_BUNDLE/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/Runtime" "$CONTENTS/Resources/Models" "$CONTENTS/Resources/Licenses"
cp "$BUILD_DIR/Noise" "$CONTENTS/MacOS/Noise"
cp Vendor/Sherpa/lib/*.dylib "$CONTENTS/Resources/Runtime/"
cp Resources/Models/* "$CONTENTS/Resources/Models/"
rm -f "$CONTENTS/Resources/Models/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx"
cp script/install_microphone.sh "$CONTENTS/Resources/"
cp script/uninstall_microphone.sh "$CONTENTS/Resources/"
cp THIRD_PARTY_NOTICES.md "$CONTENTS/Resources/"
if [[ ! -f "$ROOT_DIR/.cache/Noise.icns" ]] || [[ "$ROOT_DIR/script/make_icon.swift" -nt "$ROOT_DIR/.cache/Noise.icns" ]]; then
  swift script/make_icon.swift "$ROOT_DIR/.cache/Noise.iconset"
  /usr/bin/iconutil -c icns "$ROOT_DIR/.cache/Noise.iconset" -o "$ROOT_DIR/.cache/Noise.icns"
fi
cp .cache/Noise.icns "$CONTENTS/Resources/Noise.icns"

python3 - "$CONTENTS" "$ROOT_DIR" <<'PY'
from pathlib import Path
import plistlib, subprocess, sys
contents = Path(sys.argv[1])
version = (Path(sys.argv[2]) / "VERSION").read_text().strip()
with (contents / "Info.plist").open("wb") as f:
    plistlib.dump({
        "CFBundleExecutable": "Noise", "CFBundleIdentifier": "za.co.mvs.Noise",
        "CFBundleName": "Noise", "CFBundleDisplayName": "Noise", "CFBundlePackageType": "APPL",
        "CFBundleIconFile": "Noise.icns",
        "CFBundleShortVersionString": version, "CFBundleVersion": "1", "LSMinimumSystemVersion": "14.2",
        "NSPrincipalClass": "NSApplication", "NSHighResolutionCapable": True,
        "LSUIElement": True,
        "NSAudioCaptureUsageDescription": "Noise filters background noise from the call app you select before playing it through your headphones or speakers.",
        "NSMicrophoneUsageDescription": "Noise removes background noise from your microphone and sends your cleaned voice to Noise Microphone for your call app.",
    }, f)
# Package libraries so the app is independent of build-machine paths.
libraries = contents / "Resources/Runtime"
for lib in libraries.glob("*.dylib"):
    subprocess.run(["install_name_tool", "-id", "@loader_path/" + lib.name, str(lib)], check=True)
    linked = subprocess.check_output(["otool", "-L", str(lib)], text=True).splitlines()[1:]
    for line in linked:
        dependency = line.strip().split(" (")[0]
        name = Path(dependency).name
        target = "libonnxruntime.dylib" if name.startswith("libonnxruntime") else name
        if (libraries / target).exists() and dependency != "@loader_path/" + target:
            subprocess.run(["install_name_tool", "-change", dependency, "@loader_path/" + target, str(lib)], check=True)
PY

./script/build_microphone.sh "$CONTENTS/Resources/NoiseMicrophone.driver"
cp .cache/Noise.icns "$CONTENTS/Resources/NoiseMicrophone.driver/Contents/Resources/NoiseMicrophone.icns"
/usr/bin/codesign --force --sign - "$CONTENTS/Resources/NoiseMicrophone.driver" >/dev/null
python3 - "$ROOT_DIR" "$CONTENTS" <<'PY'
from pathlib import Path
import shutil, sys
root, contents = map(Path, sys.argv[1:])
paths = [root / "Vendor/BlackHole/LICENSE", root / "Vendor/Sherpa/LICENSE-sherpa",
         root / "Vendor/Sherpa/LICENSE-onnxruntime", root / "Vendor/Sherpa/LICENSE-dpdfnet",
         root / "Vendor/Sherpa/LICENSE-hush", root / "Vendor/Sherpa/LICENSE-hush-runtime-MIT",
         root / "Vendor/Sherpa/LICENSE-hush-runtime-APACHE"]
paths += list((root / "Vendor/RNNoise").glob("rnnoise-*/COPYING"))
paths += list((root / "Vendor/DeepFilterNet").glob("DeepFilterNet-*/LICENSE-*"))
for path in paths:
    if path.exists():
        name = path.parent.name + "-" + path.name
        shutil.copy2(path, contents / "Resources/Licenses" / name)
PY
for library in "$CONTENTS"/Resources/Runtime/*.dylib; do
  /usr/bin/codesign --force --sign - "$library" >/dev/null
done
/usr/bin/codesign --force --sign - "$APP_BUNDLE" >/dev/null

case "$MODE" in
  --build-only) echo "Built $APP_BUNDLE" ;;
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
  --debug) /usr/bin/lldb -- "$CONTENTS/MacOS/Noise" ;;
  --logs) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "Noise"' ;;
  --telemetry) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "za.co.mvs.Noise"' ;;
  --verify) /usr/bin/open -n "$APP_BUNDLE"; sleep 2; /usr/bin/pgrep -f "^$CONTENTS/MacOS/Noise" >/dev/null; echo "Noise launched successfully." ;;
esac
