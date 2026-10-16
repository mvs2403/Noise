#!/bin/bash
set -euo pipefail
SOURCE="${1:?Usage: install_microphone.sh /path/to/NoiseMicrophone.driver}"
DESTINATION="/Library/Audio/Plug-Ins/HAL/NoiseMicrophone.driver"
if [[ "$EUID" -ne 0 ]]; then echo "Administrator access is required." >&2; exit 1; fi
if [[ "$(basename "$SOURCE")" != "NoiseMicrophone.driver" ]] || [[ ! -f "$SOURCE/Contents/MacOS/NoiseMicrophone" ]]; then
  echo "The bundled Noise Microphone driver was not found." >&2; exit 1
fi
IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE/Contents/Info.plist")"
if [[ "$IDENTIFIER" != "za.co.mvs.Noise.Microphone" ]]; then echo "Unexpected driver identifier." >&2; exit 1; fi
/usr/bin/codesign --verify --strict "$SOURCE"
mkdir -p /Library/Audio/Plug-Ins/HAL
/usr/bin/ditto "$SOURCE" "$DESTINATION"
/usr/sbin/chown -R root:wheel "$DESTINATION"
/bin/chmod -R go-w "$DESTINATION"
/usr/bin/killall coreaudiod || true
