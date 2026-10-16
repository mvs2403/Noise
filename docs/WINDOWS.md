# Noise for Windows

Windows 11 x64. Private beta. Download **Noise-0.2.0-windows-x64-setup.exe**
or the portable ZIP from [the Windows release](https://github.com/mvs2403/Noise/releases/tag/v0.2.0).
The installer runs per user and includes the .NET runtime, all four filters, and
the models. No Python, Rust, Visual Studio, or administrator rights are needed
to install Noise itself. This beta installer is unsigned; Windows may show its
publisher warning. It has no automatic startup entry.

## Install audio routing devices

Windows process capture copies audio without silencing the original. An isolation
cable prevents the original and cleaned audio from playing together. Noise uses
**already installed virtual devices** and does not install a kernel driver.

One option is [VB-Audio's signed VB-CABLE](https://vb-audio.com/Cable/), installed
using its publisher's instructions. Its basic cable can serve either incoming
audio or the microphone. **Both directions at once need two independent cable
pairs**, such as existing VB-CABLE A/B devices. These drivers have their own
license and may require a donation. They are not bundled with Noise.

1. Keep Windows **default output** on your real headphones or speakers.
2. Open Noise → Settings. Choose a virtual **playback** endpoint as the Incoming
   isolation cable. For example, `CABLE-A Input` is a playback device despite its name.
3. In Windows Settings → System → Sound → **Volume mixer**, set each app you want
   to filter to that cable. Start audio in the app so its session appears.
4. In Noise's Speaker tab, click **Choose applications**, select the apps with
   checkboxes, and turn cancellation on. Use current app remembers the last app
   you used. Click a window hides the picker until you activate the target window.
5. Noise captures each selected process tree once, mixes the selected apps into
   one filter, and plays to the **current Windows default output**. Changing the
   default physical output follows automatically.

For outgoing audio:

1. Choose a **physical microphone** in Noise Settings.
2. Choose the **other cable's playback endpoint** as Cleaned microphone cable,
   for example `CABLE-B Input`.
3. Choose its paired **recording endpoint**, for example `CABLE-B Output`, as
   the microphone in Teams, Zoom, or your calling app.
4. Turn cancellation on in the Microphone tab.

Keep Windows “Listen to this device” **off** for both cables. Do not use the
incoming cable as a microphone input, and do not make either cable the default
listening output. Noise rejects conflicting endpoint selections and checks
selected apps' active sessions before capture. It stops routes if routing becomes
unsafe, a device stops, or processing falls behind.

## Everyday controls

Noise lives in the notification area, without a taskbar button. Left-click its
icon to open the two-tab panel; right-click for Open or Quit. Closing the panel
keeps audio running. The reduction slider appears while cancellation is on;
voice leveling is disabled when cancellation is off.

Once a route is running, switching cancellation **off** passes original audio
through that route and disables leveling. **Stop all / Quit stops routing**.
Because Windows routing choices are managed in Volume mixer, **restore apps to
Default output before quitting or uninstalling Noise**. Your call app should
use its physical microphone again after Noise stops.

Settings offers DPDFNet (default), DeepFilterNet3, RNNoise, and an experimental
automatic Main speaker mode for each direction. Main speaker needs no sample;
it can suppress foreground speech in difficult mixtures. All voices denoises
the mixture and levels its overall volume; it does not separately normalize
three overlapping people.

## Beta limits and troubleshooting

- Live routes start only on request after launch. Audio and models stay local.
- Reopen the chooser and Apply after launching/restarting an app or changing
  its selection. Protected/DRM audio and elevated applications may be unavailable.
- Applications sharing one executable (for example all Chrome windows) are one
  selection. Window selection chooses the application, not an individual tab.
- The Windows beta is mono at 48 kHz, intended for calls rather than music.
- **No sound:** verify the app is playing to its incoming cable, selected in
  Noise, and cancellation is on. Verify the default output is physical.
- **Echo/doubling:** switch off cable monitoring/Listen. Ensure every selected
  app is routed to the isolation cable. Call apps may need output and input
  configured inside their own settings too.
- **No microphone:** enable desktop-app microphone access in Windows privacy
  settings and choose the cleaned cable recording endpoint in the call app.
- **Device disconnected:** select an active physical output, then restart the route.

The build verifies all four native engines and launches the Windows UI on a
native Windows runner. Physical-device audio quality, Teams interoperability,
Bluetooth changes, and third-party driver configurations still need testing
on a Windows PC. The package is a beta, not a claim of hardware certification.

## Build from source

Use Windows 11 x64, .NET SDK 10, Visual Studio C++ build tools with the x64 toolset,
Python 3.12+, Rust/rustup, CMake, and NSIS (or Chocolatey to install NSIS).
Run `pwsh ./script/build_desktop.ps1`. It downloads pinned inputs, builds native
filters, runs offline tests and a GUI smoke test, and produces `dist/desktop`.
The GitHub **Desktop packages** workflow performs this same native build.
