# iOS and Android

Status checked against platform documentation on **17 October 2026**. There are
no Noise mobile applications or mobile installation packages in this repository
yet. The mobile product scope needs to account for the limits below.

## Calls in other applications

The desktop application captures selected application streams, suppresses their
original playback, and renders cleaned audio. Its virtual microphone provides
processed audio to another calling application. A mobile UI alone cannot
reproduce those routes.

| Capability | iOS | Android, ordinary installed app |
| --- | --- | --- |
| Filter a Teams/FaceTime/phone call carried by another app | No supported access to that call's audio | Playback capture excludes voice communication; call capture requires privileged access |
| Replace another app's microphone with a Noise virtual input | No general desktop-style virtual microphone API | No general desktop-style virtual microphone API |
| Capture eligible media playing in another app | Not equivalent to the macOS process-tap route | Android 10+ can copy eligible media/game/unknown-usage audio with user consent and the source app's capture policy |
| Process audio recorded or opened inside Noise | Feasible | Feasible |
| Process both directions of calls carried inside Noise | Feasible with a separate calling implementation | Feasible with a separate calling implementation |

Apple's Developer Technical Support explicitly states that an iOS application
cannot access live audio from a call it does not carry. The Core Audio process
tap and HAL driver approach used by Noise is a macOS approach.

Android's AudioPlaybackCapture API makes a copy of eligible playback. It does
not provide the original-stream suppression needed by Noise's desktop listening
route. Capturing and replaying cleaned media alone would leave the original
audio audible as well, so it would not deliver the promised replacement audio.
Call audio is outside the permitted playback usages. Microphone sharing also
does not let an ordinary application substitute its processed buffer for a
different application's microphone.

## Apple microphone injection

iOS 18.2+ includes an accessibility feature that adds an application's audio to
supported calls with permission. Apple's sample describes adding synthesized
speech **alongside** microphone input. It does not expose the other party's audio
or supply a general replacement for the original microphone signal. It is not
a solution for the two-way filtering requirement.

## Feasible mobile directions

- **Recorder and audio-file cleanup:** denoise audio captured or imported inside
  Noise, adjust reduction and voice leveling, compare, and export locally.
- **Calls inside Noise:** own the incoming and outgoing PCM streams and process
  both directions. This needs its own calling transport, connection flow, and
  mobile lifecycle handling; it does not filter a separate Teams app.

The portable C++ processing core can support either direction once mobile
libraries are built and validated. Desktop binaries cannot be copied directly
into mobile packages. No claim of mobile engine compatibility or performance
has been validated yet.

## Primary sources

- [Apple DTS: access to a call an app does not carry](https://developer.apple.com/forums/thread/841340).
- [Apple: capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).
- [Apple: adding synthesized speech to calls](https://developer.apple.com/documentation/avfaudio/adding-synthesized-speech-to-calls).
- [Android: capture video and audio playback](https://developer.android.com/media/platform/av-capture).
- [Android: sharing audio input](https://developer.android.com/media/platform/sharing-audio-input).
