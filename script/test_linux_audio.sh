#!/usr/bin/env bash
set -euo pipefail
noise_stage="$1"
noise_mode="${2:-pulse}"
noise_test_dir="$(mktemp -d)"
export XDG_RUNTIME_DIR="$noise_test_dir/runtime"
export NOISE_DATA_DIR="$noise_test_dir/data"
mkdir -m 700 -p "$XDG_RUNTIME_DIR"
noise_pids=()
cleanup() {
  noise_result=$?
  if [ "$noise_result" -ne 0 ]; then
    for noise_log in "$noise_test_dir/"*.log; do [ ! -f "$noise_log" ] || cat "$noise_log"; done
  fi
  if [ "${#noise_pids[@]}" -gt 0 ]; then kill "${noise_pids[@]}" 2>/dev/null || true; fi
  rm -rf "$noise_test_dir"
  return "$noise_result"
}
trap cleanup EXIT
if [ "$noise_mode" = pipewire ]; then
  unset PULSE_RUNTIME_PATH PULSE_STATE_PATH
  export PULSE_SERVER="unix:$XDG_RUNTIME_DIR/pulse/native"
  pipewire >"$noise_test_dir/pipewire.log" 2>&1 & noise_pids+=("$!")
  pipewire-pulse >"$noise_test_dir/pulse.log" 2>&1 & noise_pids+=("$!")
  wireplumber >"$noise_test_dir/wireplumber.log" 2>&1 & noise_pids+=("$!")
  noise_ready=0
  for noise_attempt in $(seq 1 100); do
    if pactl info >/dev/null 2>&1; then noise_ready=1; break; fi
    sleep .1
  done
  if [ "$noise_ready" = 0 ]; then cat "$noise_test_dir/"*.log; exit 1; fi
  pactl load-module module-null-sink sink_name=test_default rate=48000 channels=1 >/dev/null
  # Pulse can accept clients before WirePlumber creates default-device metadata.
  # Wait for the policy manager as well as the protocol socket.
  noise_ready=0
  for noise_attempt in $(seq 1 100); do
    if pactl set-default-sink test_default >"$noise_test_dir/default.log" 2>&1 && [ "$(pactl get-default-sink)" = test_default ]; then noise_ready=1; break; fi
    sleep .1
  done
  if [ "$noise_ready" = 0 ]; then exit 1; fi
  NOISE_TEST_AUDIO=1 dotnet "$noise_stage/Noise.dll" --routing-self-test
else
  export PULSE_RUNTIME_PATH="$noise_test_dir/pulse-runtime"
  export PULSE_STATE_PATH="$noise_test_dir/state"
  export PULSE_SERVER="unix:$noise_test_dir/native"
  mkdir -m 700 -p "$PULSE_RUNTIME_PATH" "$PULSE_STATE_PATH"
  pulseaudio -n --daemonize=no --exit-idle-time=-1 --use-pid-file=no \
    --load="module-native-protocol-unix socket=$noise_test_dir/native auth-anonymous=1" \
    --load="module-null-sink sink_name=test_default rate=48000 channels=1" >"$noise_test_dir/pulse.log" 2>&1 & noise_pids+=("$!")
  for noise_attempt in $(seq 1 100); do
    if pactl info >/dev/null 2>&1; then break; fi
    sleep .1
  done
  NOISE_TEST_AUDIO=1 dotnet "$noise_stage/Noise.dll" --routing-self-test
  echo 'PASS PulseAudio end-to-end routing'
  if [ "$noise_mode" = all ]; then
    dbus-run-session -- "$0" "$noise_stage" pipewire
    echo 'PASS PipeWire-Pulse end-to-end routing'
  fi
fi
