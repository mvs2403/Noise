<p align="center">
  <img src="docs/images/noise-icon.png" width="88" alt="Noise app icon">
</p>

<h1 align="center">Noise</h1>
<p align="center"><strong>Clear calls. Both ways.</strong><br>
Noise cancellation for the apps you hear and the microphone others hear.</p>
<p align="center">
  <a href="https://github.com/mvs2403/Noise/releases/download/v0.1.0/Noise-0.1.0-apple-silicon.dmg"><strong>Download for Mac</strong></a>
  · <a href="https://github.com/mvs2403/Noise/releases">All releases</a>
  · <a href="#quick-start">Quick start</a>
  · <a href="docs/DEVELOPMENT.md">Developer guide</a>
</p>
<p align="center">macOS 14.2+ · Windows 11 x64 · Linux x64 · Public beta</p>

Noise processes call audio locally on your device. Clean the sound arriving from
Teams, Zoom, a browser, or several apps together, and optionally send a cleaned
microphone to your call app. Each direction has independent controls.

## Downloads

| Platform | Package | Setup |
| --- | --- | --- |
| macOS 14.2+, Apple Silicon | [DMG · 0.1.0](https://github.com/mvs2403/Noise/releases/download/v0.1.0/Noise-0.1.0-apple-silicon.dmg) | [Mac quick start](#quick-start) |
| Windows 11, x64 | [Installer · 0.3.0](https://github.com/mvs2403/Noise/releases/download/v0.3.0/Noise-0.3.0-windows-x64-setup.exe) · [Portable ZIP](https://github.com/mvs2403/Noise/releases/download/v0.3.0/Noise-0.3.0-windows-x64.zip) | [Windows routing guide](docs/WINDOWS.md) |
| Linux x64, glibc 2.39+ | [Debian package · 0.3.0](https://github.com/mvs2403/Noise/releases/download/v0.3.0/Noise-0.3.0-linux-x64.deb) · [Portable archive](https://github.com/mvs2403/Noise/releases/download/v0.3.0/Noise-0.3.0-linux-x64.tar.gz) | [Linux setup](docs/LINUX.md) |

Windows uses installed virtual audio devices. Two independent cable pairs are
needed for both directions together; drivers are installed separately. The
installer includes the filters and .NET runtime and is unsigned. The repository
and release downloads are public; no GitHub account is required.

Linux routes selected apps automatically through PulseAudio/PipeWire-Pulse and
provides a virtual microphone. Window picking requires X11; checkboxes work on Wayland.

**Mobile:** iOS and Android cannot offer the desktop app's filtering of other
apps' calls through ordinary public APIs. Mobile scope is being evaluated;
there is no iOS or Android release yet. See [mobile capabilities](docs/MOBILE.md).

<table>
  <tr><th>Windows</th><th>Linux</th></tr>
  <tr>
    <td><img src="docs/images/windows-controls.png" width="300" alt="Windows panel with Speaker and Microphone tabs, application selection, and voice leveling disabled while cancellation is off"></td>
    <td><img src="docs/images/linux-controls.png" width="300" alt="Linux panel with Speaker and Microphone tabs, application selection, and voice leveling disabled while cancellation is off"></td>
  </tr>
</table>

*Windows and Linux 0.3.0 screenshots from native build checks, with sample app selections.*

<table>
  <tr>
    <th>Speaker · What you hear</th>
    <th>Microphone · What they hear</th>
  </tr>
  <tr>
    <td align="center"><img src="docs/images/menu-speaker.png" width="300" alt="Speaker menu controls with selected apps, cancellation, a noise reduction slider, and voice leveling"></td>
    <td align="center"><img src="docs/images/menu-microphone.png" width="300" alt="Microphone menu controls with cancellation off and voice leveling greyed out"></td>
  </tr>
</table>

*The macOS screenshots show the native interface with sample app and device labels.*

## What it does

- **Clean incoming audio.** Select one or more applications. Their audio shares
  one filter; other apps keep playing normally.
- **Clean your microphone.** Send processed speech through **Noise Microphone**,
  the optional virtual microphone selected inside your call app.
- **Keep volume steadier.** Voice leveling raises quiet speech and softens loud
  speech after filtering. It stops with cancellation and remembers your choice.
- **Adjust reduction live.** A 0–100% slider appears beneath cancellation in the
  menu bar while enabled. Each direction remembers its own strength.
- **Follow your system output.** Switching headphones or speakers reconnects
  Noise to the current output. On macOS, a fixed override is also available.
- **Stay out of the way.** Use the menu bar on macOS or the tray on Windows
  and Linux. Linux keeps an accessible window if the desktop lacks a tray host.

DPDFNet is the default engine. Settings also offers DeepFilterNet3, RNNoise, and
an experimental automatic **Main speaker** mode. No voice enrollment is needed.

| Routing | macOS | Windows | Linux |
| --- | --- | --- | --- |
| Selected apps | Automatic process capture | Route apps to an installed virtual cable in Volume mixer, then select them in Noise | Automatic routing through PulseAudio/PipeWire-Pulse |
| Microphone in your call app | **Noise Microphone**, after optional driver setup | The recording endpoint paired with your second virtual cable | **Noise_Microphone**, created by Noise |
| App selection | Checkboxes, current app, click a window | Checkboxes, current app, click a window | Checkboxes; current app and window picking require X11 and xdotool |
| Before quitting | Return your call app to its physical microphone | Restore apps to Default output and your call app to its physical microphone | Return your call app to its physical microphone; Noise restores selected app routes |

## Install

The steps below describe macOS. Use the [Windows guide](docs/WINDOWS.md) or
[Linux guide](docs/LINUX.md) for their packages and audio setup.

1. Download the [Apple Silicon DMG](https://github.com/mvs2403/Noise/releases/download/v0.1.0/Noise-0.1.0-apple-silicon.dmg).
2. Open it and drag **Noise.app** to **Applications**.
3. Eject the disk image, then open Noise from Applications. Look for its waveform
   icon in the macOS menu bar.

All engines and models are bundled. You do **not** need Xcode, Python, Rust, or
additional model downloads to use the app. A ZIP is available among the
[release files](https://github.com/mvs2403/Noise/releases/tag/v0.1.0).

> **Beta signing:** this build is ad hoc signed and is **not notarized**.
> macOS may block its first launch. After trying to open it, follow Apple's
> per-app [Open Anyway instructions](https://support.apple.com/102445) in
> **System Settings → Privacy & Security**, if that option is available.
> See the [distribution guide](docs/DISTRIBUTION.md) for signing status and checksums.

## Quick start

### Clean what you hear

1. Open Noise's waveform menu-bar icon and select the **Speaker** tab.
2. Click the large applications button. Check the apps you want, then **Done**.
   **Use current app** adds the last active app outside Noise; **Pick a window…**
   lets you choose an app by clicking its window or Dock icon.
3. Turn **Noise cancellation** on and allow **System Audio Recording** when
   macOS asks. If the selected apps are idle, Noise waits for their audio.
4. Adjust **Noise reduction** underneath the switch. Enable **Voice leveling**
   for steadier speech volume.

<img src="docs/images/app-selection.png" width="450" alt="Application chooser with multi-app checkboxes, search, Use current app, and Pick a window">

Selections are remembered, including closed apps. Selecting a browser includes
audio across all its tabs. Before macOS 26, an app may need to play audio before
Core Audio exposes it for capture.

**Follow Mac output** routes to the currently selected macOS headphones or
speakers. Change the Mac's output as usual; Noise reconnects automatically with
a brief transition. The main window's **Listen through** selector also allows a
fixed output when you deliberately want one.

Turning incoming cancellation off restores the selected apps' original audio.

### Clean what they hear

1. Open **Noise Settings → Outgoing microphone → Set Up Virtual Microphone**.
   This optional, one-time installation requires administrator access and briefly
   restarts audio. Set it up **before joining a call**.
2. In Noise's main window, choose your physical microphone under **Your microphone**.
3. In Teams, Zoom, or the other call app, select **Noise Microphone** as its input.
4. Open the menu-bar **Microphone** tab and turn cancellation on. Adjust its
   reduction strength and leveling independently of the Speaker tab.

Turning microphone cancellation off passes your original voice through the
virtual microphone. **Stop All** or quitting Noise stops that route completely.
Return the call app to your physical microphone before stopping or quitting.

<img src="docs/images/main-window.png" width="900" alt="Noise main window with independent incoming and outgoing audio controls, application selection, Follow Mac output, engine selection, and comparison controls">

Headphones help avoid speaker-to-microphone feedback. Keep the call app's acoustic
echo cancellation available; noise suppression does not replace it.

## Choose voices and engines

In **Settings**, choose independently for incoming audio and your microphone:

| Mode | Behavior |
| --- | --- |
| **All voices** | Reduce room noise while retaining speech from everyone. Uses your chosen DPDFNet, DeepFilterNet3, or RNNoise engine. |
| **Main speaker · Experimental** | Automatically favor the dominant foreground voice and reduce quieter background voices using Hush. No sample or saved identity is required. |

Main speaker is useful to try when one voice is clearly stronger or nearer the
microphone. It can also soften the intended voice or retain competing talkers.
Similar-volume voices, heavy overlap, and calls that already equalized everybody
are difficult. It cannot recover individual meeting-participant tracks from an
app's combined audio.

<img src="docs/images/settings.png" width="560" alt="Noise settings showing All voices and Main speaker choices, engine selection, noise reduction strength, and voice leveling for each direction">

| Engine | Intended option |
| --- | --- |
| **DPDFNet · Default** | Full-band speech enhancement at 48 kHz |
| **DeepFilterNet3** | An alternative full-band speech enhancer at 48 kHz |
| **RNNoise** | A lightweight speech denoiser at 48 kHz |
| **Hush · Main speaker** | Automatic foreground speech enhancement at 16 kHz speech bandwidth |

Use **Open Noise → Original / Cleaned** to compare while a path is running.
Original bypasses all effects. Switching engines or voice modes reconnects that
path. Lower strength blends more original sound back in; higher strength applies
more of the selected filter. Overlapping voices are leveled as a combined signal.

## Privacy and permissions

Processing runs on your device. Noise does not record, transcribe, or upload calls.
Incoming filtering needs **System Audio Recording** permission; outgoing
filtering also needs **Microphone** permission. The optional virtual driver asks
for administrator access only during installation/removal.

Noise does not change the Mac's default input or output. Follow Mac output
observes the existing selection. Hiding menu-bar controls in Settings restores a
Dock icon so the running app remains reachable.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Selected apps are silent or show a connection wait | Respond to any pending macOS audio-recording permission dialog, even if Noise already has a checked entry in Privacy & Security. |
| No app appears in the chooser | Open it, start audio playback, and use Refresh Apps & Devices in the main window. |
| Noise Microphone is missing | Install it from Settings, then refresh devices. macOS may need a sign-out/restart if its audio service has not registered the driver. |
| Call participants cannot hear you after quitting | Select your physical microphone in the call app; the virtual microphone is silent while Noise is not feeding it. |
| Filtering struggles or affects the voice | Try All voices, reduce strength, or compare another engine. Main speaker is experimental. |
| The waveform icon is hidden | Check the menu bar's overflow area or reopen Noise; show menu-bar controls in Settings. |

To remove the optional driver, first return call apps to a physical microphone,
quit Noise, then run the included uninstaller. It asks for administrator access
and briefly interrupts audio:

```sh
sudo /bin/bash /Applications/Noise.app/Contents/Resources/uninstall_microphone.sh
```

Remove Noise.app from Applications afterward.

## Development and release status

This is a development beta. Processing is mono and intended for speech, including
all sound from selected apps. Music, shared videos, and notifications from those
apps are filtered too. Background voices and distortion can remain.

**28 macOS audio tests pass.** Local checks cover engine streaming, reduction
strength, leveling, peak protection, queue integrity, multi-app selection,
foreground sessions, and output-routing policy. Two local apps have played through
a shared incoming route. Live Teams routing, administrator driver installation,
and changing hardware outputs during a live call still need hands-on validation.
These checks do not establish speech quality across calls.

**Windows and Linux packages pass native automated checks** for all four engines,
strength and bypass behavior, leveling, bounded queues, and UI launch. Linux
also passes generated-audio routing checks on both PulseAudio and PipeWire,
including multi-app filtering, virtual microphone capture, system-output changes,
audible restarts, and crash recovery. Physical devices, Bluetooth, and real
calling-app compatibility still need hands-on testing on each platform.

```sh
git clone https://github.com/mvs2403/Noise.git
cd Noise
./script/build_and_run.sh --verify
```

Building needs an Apple Silicon Mac, Xcode with Swift 6+, and Python 3.12+.
The first build fetches pinned dependencies; subsequent use works offline.

- [Windows setup and development](docs/WINDOWS.md).
- [Linux setup and development](docs/LINUX.md).
- [iOS and Android capabilities](docs/MOBILE.md).
- [Developer guide](docs/DEVELOPMENT.md): macOS build commands, tests, DSP behavior and architecture.
- [Distribution guide](docs/DISTRIBUTION.md): packaging, checksums, public downloads and signing.
- Release notes: [macOS 0.1.0](docs/releases/0.1.0.md),
  [Windows 0.2.0](docs/releases/0.2.0.md), and
  [Linux and refreshed Windows 0.3.0](docs/releases/0.3.0.md).
- [Third-party notices](THIRD_PARTY_NOTICES.md): upstream projects, revisions and licenses.

The separately bundled Noise Microphone driver is derived from BlackHole and is
GPL-3.0. Its source and build scripts are included in the repository and matching
release source archive. Upstream models and runtimes retain their own licenses;
license texts are included inside the app.
