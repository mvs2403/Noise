# Development

## Build and run

Requirements: an Apple Silicon Mac, macOS 14.2+, Xcode/command-line tools with
Swift 6+, and Python 3.12+. The initial dependency build needs internet access.

```sh
./script/build_and_run.sh
./script/build_and_run.sh --verify
./script/build_and_run.sh --build-only
./script/build_and_run.sh --debug
./script/build_and_run.sh --logs
```

The canonical script builds, stages and locally signs `dist/Noise.app`. It is
also the Codex Run command. Pinned model downloads and a private Rust toolchain
stay in `.cache/`; native build products stay in `Vendor/` and `.build/`. No
global Rust installation is required. Release packaging is documented in
[Distribution](DISTRIBUTION.md).

## Verification

```sh
swift test
swift run NoiseCheck
python3 script/validate_bundle.py dist/Noise.app
swift run NoiseCheck verify-bundle dist/Noise.app
```

The 28 audio tests cover streaming, stationary-noise reduction, original-audio
bypass, strength mixing, voice leveling and limiting, bounded queues, multi-app
selection/persistence, default-output routing policy, voice-mode migration,
missing models, and independent foreground-enhancement sessions.

`verify-bundle` loads all four engines from the supplied app's resources and
processes generated audio without recording live inputs. Bundle validation also
checks arm64 support, minimum macOS versions, signatures, and portable dynamic
library references.

For a repeatable local listening comparison:

```sh
swift run NoiseCheck benchmark /absolute/path/to/noisy.wav .cache/comparison
swift run NoiseCheck benchmark /absolute/path/to/noisy.wav .cache/comparison --level
swift run NoiseCheck benchmark /absolute/path/to/noisy.wav .cache/foreground --main-speaker --level
```

The tool writes local WAVs and JSON timing/peak results. It does not upload audio
or infer a speech-quality ranking. Outputs retain each engine's startup delay.

## Audio paths

- Incoming: a Core Audio process tap captures the union of selected apps/helper
  processes, mutes those original streams while connected, processes one mixed
  mono stream, and plays it through the chosen output. Other apps are unaffected.
- Outgoing: the physical microphone feeds an independent processing chain, which
  writes to the Noise Microphone loopback driver. Turning cancellation off
  preserves a raw microphone route; Stop All ends that route.
- Follow Mac output resolves the system default output on change notifications,
  with periodic discovery as a fallback. Device changes received during setup
  are coalesced before reconnecting. An explicit device choice stays pinned by UID.
- Native callbacks use bounded queues; denoising runs on a worker thread. Route
  ownership transitions are serialized by `AudioRouter`.

## DSP behavior

Noise reduction blends original and cleaned signals **after aligning their
delays**: DPDFNet 50 ms, DeepFilterNet3 30 ms, RNNoise 20 ms, and Main speaker
670 samples at 48 kHz (about 14 ms). Capture/playback buffers add latency.

Leveling follows enhancement. Speech-aware gain targets about −20 dBFS RMS,
allows −24 to +18 dB adjustment, and limits peaks to −1 dBFS. Quiet pauses do not
trigger unlimited gain. The mixed signal is leveled as a whole; overlapping
speakers are not independently normalized. Original bypasses every effect.

Main speaker uses the pinned Hush 16 kHz foreground model, bridged to/from 48 kHz
with stateful anti-alias FIR filters. It needs no voice identity or enrollment.
It is experimental: controlled mixtures showed variable foreground preservation
and background suppression, including attenuation of intended speech.

Legacy `mine`/`selected` preferences map to Main speaker. Old profile files are
preserved but no longer read. Last-used output preferences from the original
device-pinning behavior default to Follow Mac output.

## Hands-on checks still needed

Two local apps have been checked through a shared DPDFNet playback route. The
optional administrator-installed virtual microphone, real Teams calls, and
physical output switching during a live call still need verification on a
recipient's Mac. Passing local tests is not a claim of consistent speech quality
across rooms or calls.

If macOS holds capture setup inside a permission dialog, resolve that dialog
before diagnosing the audio service. A pending System Audio Recording prompt can
appear even when Noise already has a checked entry in System Settings.
