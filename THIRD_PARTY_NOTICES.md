# Third-party components

Noise uses independent, local instances of the chosen engine for each audio direction.

- **DPDFNet** by Ceva: Apache-2.0. Model: `dpdfnet2_48khz_hr.onnx`.
  Source: https://github.com/ceva-ip/DPDFNet
- **sherpa-onnx v1.13.8**: Apache-2.0. The unmodified public C API header is
  included in `Sources/CNoiseRuntime/SherpaAPI.h`.
  Source: https://github.com/k2-fsa/sherpa-onnx/tree/v1.13.8
- **ONNX Runtime**: MIT; bundled with sherpa-onnx.
  Source: https://github.com/microsoft/onnxruntime
- **Hush** by Weya / pulp-vision: Apache-2.0 model and project source; the
  `weya_nc` C-ABI wrapper declares MIT, and its vendored DeepFilterNet runtime is
  MIT / Apache-2.0. Source revision `9f6414e91461a8f4bdf9840c0cdcdcb7da986339`;
  compiled locally as `libweya_nc.dylib`. Model revision
  `a55d932cbf6344d284ac985f21e7f6e5bc4d38a5`, SHA-256
  `45632ccaa82b71bb743d6caa7c78e983fe2f2790a3af7f6ec48e6ed7ba085df6`.
  Sources: https://github.com/pulp-vision/Hush and https://huggingface.co/weya-ai/hush
- **DeepFilterNet3** by Hendrik Schröter and contributors: MIT / Apache-2.0.
  Pinned source revision `d375b2d8309e0935d165700c91da9de862a99c31`; built locally
  as `libdf.dylib` with its official C API and the matching model archive.
  Source: https://github.com/Rikorose/DeepFilterNet
- **RNNoise** by Jean-Marc Valin, Xiph.Org and contributors: BSD-3-Clause.
  Pinned source revision `70f1d256acd4b34a572f999a05c87bf00b67730d` and the model
  checksum specified in that revision's `model_version`.
  Source: https://github.com/xiph/rnnoise
- **Noise Microphone** is a separately built, renamed two-channel **BlackHole**
  loopback driver by Existential Audio Inc., licensed under GPL-3.0.
  Its complete pinned upstream C source and license are included in
  `Vendor/BlackHole/`; revision `561d934c77a1fa64987e01ccabe890fed30e181f`.
  The build changes only the driver name, device UID, bundle/factory identifiers,
  and volume-control configuration via compiler flags and the bundle plist.
  Source: https://github.com/ExistentialAudio/BlackHole

Upstream license texts are copied into the built application's `Resources/Licenses`.
The driver also contains its GPL license. Preserve these notices and the driver
source/build instructions when distributing it. Current macOS beta packages are
ad hoc signed and are not notarized. Production macOS distribution requires
distribution signing and notarization.

## Windows desktop components

The Windows build does not bundle BlackHole. Its native libraries and license
texts are in `Runtime/` and `Licenses/` beside the executable. Installed Windows
virtual devices are provided and licensed separately by their vendors.

- Avalonia 12.1.4 and its Fluent theme: MIT, https://github.com/AvaloniaUI/Avalonia
- NAudio.Wasapi 3.2.0: MIT, https://github.com/naudio/NAudio
- .NET 10 self-contained runtime: MIT and third-party notices included by the
  .NET SDK in each published package, https://github.com/dotnet/runtime
- SkiaSharp / Skia and HarfBuzz native dependencies are distributed through
  Avalonia's pinned NuGet dependency graph. The package lock records exact
  versions; their upstream license notices accompany the desktop distribution.

The same pinned DPDFNet, sherpa-onnx, ONNX Runtime, DeepFilterNet3, RNNoise, and
Hush inputs above are used for desktop builds. Build scripts retain checksums,
and release source archives include the shared DSP and reproducible build scripts.

On Windows, sherpa-onnx's DLL import name is changed from `onnxruntime.dll` to
`noise_ort.dll`, and the bundled ONNX Runtime DLL is renamed to match. This avoids
Windows' older inbox runtime. Inference code and model weights are unchanged.
The patch is in `script/private_windows_runtime.py`; the distribution includes
`Licenses/NATIVE-MODIFICATIONS.txt`.

Linux uses the system libpulse client library (LGPL-2.1-or-later) and the installed
PulseAudio/PipeWire-Pulse server. These system components are not bundled. The
native helper links dynamically against libpulse; its source and build instructions
are included. `pactl` and optional `xdotool` are installed system utilities.
