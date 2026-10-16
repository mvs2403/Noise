#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
noise_version="$(cat VERSION)"
noise_stage="$PWD/.cache/linux-package"
noise_dist="$PWD/dist/desktop"
mkdir -p "$noise_stage" "$noise_dist"
dotnet restore Desktop/Noise.Desktop.csproj --locked-mode
dotnet publish Desktop/Noise.Desktop.csproj -c Release -r linux-x64 --self-contained true -o "$noise_stage" /p:Version="$noise_version"
python3 script/bootstrap_desktop.py --output "$noise_stage"
dotnet "$noise_stage/Noise.dll" --self-test
# The disposable CI audio server contains only generated fixtures, never user audio.
(
  noise_test_dir="$(mktemp -d)"
  export PULSE_RUNTIME_PATH="$noise_test_dir/runtime"
  export PULSE_STATE_PATH="$noise_test_dir/state"
  export PULSE_SERVER="unix:$noise_test_dir/native"
  export NOISE_DATA_DIR="$noise_test_dir/data"
  mkdir -p "$PULSE_RUNTIME_PATH" "$PULSE_STATE_PATH"
  trap 'pulseaudio --kill >/dev/null 2>&1 || true; rm -rf "$noise_test_dir"' EXIT
  pulseaudio -n --daemonize=yes --exit-idle-time=-1 --use-pid-file=yes \
    --load="module-native-protocol-unix socket=$noise_test_dir/native auth-anonymous=1" \
    --load="module-null-sink sink_name=test_default rate=48000 channels=1"
  NOISE_TEST_AUDIO=1 dotnet "$noise_stage/Noise.dll" --routing-self-test
)
dbus-run-session -- xvfb-run -a "$noise_stage/Noise" --smoke-ui
cp "$noise_stage/windows-controls.png" "$noise_dist/linux-controls.png"
rm "$noise_stage/windows-controls.png"
cp docs/LINUX.md "$noise_stage/START-HERE.md"
cp README.md VERSION "$noise_stage/"
cp -R docs "$noise_stage/"
python3 script/package_linux.py --stage "$noise_stage" --output "$noise_dist"
git archive --format=tar.gz --prefix="Noise-$noise_version/" -o "$noise_dist/Noise-$noise_version-source.tar.gz" HEAD
python3 script/desktop_manifest.py --platform linux-x64 --stage "$noise_stage" --output "$noise_dist"
python3 - "$noise_dist" <<'PY'
import sys,hashlib
from pathlib import Path
root=Path(sys.argv[1])
(root/'SHA256SUMS.txt').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n' for p in sorted(root.iterdir()) if p.is_file() and p.name!='SHA256SUMS.txt'))
PY
