#!/bin/bash
set -euo pipefail
if [[ "$EUID" -ne 0 ]]; then echo "Run with sudo to remove Noise Microphone." >&2; exit 1; fi
DESTINATION="/Library/Audio/Plug-Ins/HAL/NoiseMicrophone.driver"
if [[ ! -d "$DESTINATION" ]]; then echo "Noise Microphone is not installed."; exit 0; fi
IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DESTINATION/Contents/Info.plist")"
if [[ "$IDENTIFIER" != "za.co.mvs.Noise.Microphone" ]]; then echo "Unexpected driver identifier; refusing removal." >&2; exit 1; fi
/bin/rm -rf "$DESTINATION"
/usr/bin/killall coreaudiod || true
