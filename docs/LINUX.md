# Noise for Linux

Linux x64, glibc 2.39+, with an existing **PipeWire-Pulse or PulseAudio** desktop
audio server. Ubuntu 24.04+ is the build baseline. This is an unsigned public beta.

Download the Debian package or portable archive from
[release 0.3.0](https://github.com/mvs2403/Noise/releases/tag/v0.3.0).

```sh
sudo apt install ./Noise-0.3.0-linux-x64.deb
```

Launch Noise from your application launcher. The package includes .NET, all four
filters, models, and licenses. For the portable version, extract its folder and
run `./Noise`. No kernel audio driver is needed.

## Incoming audio

1. Play audio in the apps you want to clean so they appear in the chooser.
2. Open Speaker → Choose applications and tick one or more apps.
3. Turn cancellation on. Apps are routed automatically into one shared filter.
4. Adjust the reduction slider and Voice leveling toggle as needed.

New streams from selected apps are picked up while filtering runs. Noise leaves
other apps under the desktop's normal routing policy. System output changes reconnect Noise automatically, with a
brief pause. Removing an app or stopping restores its previous output; apps
that started on the default return to the current system default.

## Microphone

Choose a physical microphone in Settings, turn cancellation on in the Microphone
tab, and select **Noise_Microphone** as your calling app's microphone.

Each direction supports DPDFNet (default), DeepFilterNet3, and RNNoise. Automatic
Main speaker mode uses the experimental Hush model without a voice sample; it
can attenuate foreground speech in difficult mixtures. All voices denoises and
levels the mixture as a whole.

Cancellation off passes original audio through the active route and disables
leveling. **Stop all** restores apps and silences the virtual microphone. The
silent microphone stays available until Quit. Choose your physical microphone
in the call app before quitting, as apps can fall back when a device disappears.
Keep the system listening output on real speakers/headphones.

## Desktop compatibility and recovery

- Checkboxes work on X11 and Wayland. Current-app and window picking require
  an X11 session and `xdotool`; Wayland restricts global window inspection.
- Tray controls require a StatusNotifier/AppIndicator host. KDE and Ubuntu's
  usual indicator setup provide one. Without a host, the control window remains
  accessible in the taskbar and closing minimizes it.
- Browser/Flatpak apps can share an audio identity. Selection applies to the
  whole application, rather than a tab or an individual window.
- Processing is mono at 48 kHz, intended for calls rather than music.
- Normal Quit restores apps and removes temporary devices. After a crash or
  forced kill, relaunch Noise to recover saved routes. Audio helpers terminate
  with their parent. Noise does not change persistent audio configuration files.

Validation uses native filter tests, GUI launch, and generated audio in a disposable
PulseAudio server. Physical devices, Bluetooth, distro policies, and calling apps
still need device testing.

## Dependencies and development

The portable package requires libstdc++ 13+, libpulse0, pulseaudio-utils,
X11/XWayland, fontconfig, FreeType, ICU, OpenSSL 3, and zlib. Install xdotool for
X11 picking and libglib2.0-bin for tray detection. The Debian package declares
these dependencies.

Build on Ubuntu 24.04 x64 with .NET SDK 10, Python 3.12+, Rust/rustup, CMake,
pkg-config, libpulse-dev, patchelf, PulseAudio, Xvfb, and dbus-x11 using
`script/build_desktop_linux.sh`. Routing tests must run only in a disposable
audio session with `NOISE_TEST_AUDIO=1` and a separate `NOISE_DATA_DIR`; the build
script creates both automatically. They generate audio and temporarily change
only that isolated server's output. Packages are written to `dist/desktop`.

A separate CI compatibility job runs the same routing checks with PipeWire-Pulse
and WirePlumber. These servers are tested in separate hosts so their system
packages do not need to coexist.
