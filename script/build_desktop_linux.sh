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
python3 - "$noise_stage" <<'PY'
import subprocess, sys
from pathlib import Path
stage = Path(sys.argv[1])
for p in [stage/'Noise', stage/'Runtime/noise-audio', *sorted(stage.glob('*.so*')), *sorted((stage/'Runtime').glob('*.so*'))]:
    if p.is_symlink(): continue
    linked = subprocess.run(['ldd', str(p)], capture_output=True, text=True, check=True).stdout
    if 'not found' in linked: raise SystemExit(f'Unresolved native dependency in {p.name}:\n{linked}')
print('PASS packaged native dependencies resolve')
PY
dotnet "$noise_stage/Noise.dll" --self-test
# The disposable CI audio server contains only generated fixtures, never user audio.
./script/test_linux_audio.sh "$noise_stage" pulse
dbus-run-session -- xvfb-run -a "$noise_stage/Noise" --smoke-ui
cp "$noise_stage/windows-controls.png" "$noise_dist/linux-controls.png"
rm "$noise_stage/windows-controls.png"
cp docs/LINUX.md "$noise_stage/START-HERE.md"
cp README.md VERSION "$noise_stage/"
cp -R docs "$noise_stage/"
python3 script/package_linux.py --stage "$noise_stage" --output "$noise_dist"
test "$(dpkg-deb --field "$noise_dist/Noise-$noise_version-linux-x64.deb" Architecture)" = amd64
test "$(dpkg-deb --field "$noise_dist/Noise-$noise_version-linux-x64.deb" Version)" = "$noise_version"
git archive --format=tar.gz --prefix="Noise-$noise_version/" -o "$noise_dist/Noise-$noise_version-source.tar.gz" HEAD
python3 script/desktop_manifest.py --platform linux-x64 --stage "$noise_stage" --output "$noise_dist"
python3 - "$noise_dist" <<'PY'
import sys,hashlib
from pathlib import Path
root=Path(sys.argv[1])
(root/'SHA256SUMS.txt').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n' for p in sorted(root.iterdir()) if p.is_file() and p.name!='SHA256SUMS.txt'))
PY
