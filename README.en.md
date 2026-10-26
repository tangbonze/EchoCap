# EchoCap

**Live captions for anything your Mac plays.** A menu-bar app that floats above every window, with the audio never leaving the machine.

[简体中文](README.md) · English

![The overlay: stacked history captions above the live caption and its translation](overlay-preview.png)

---

## What this is

A reimplementation of the product at [subtitles-live.com](https://subtitles-live.com/): it **captures whatever the Mac is playing** — calls, podcasts, videos, lectures, streams — recognises it on-device, and draws it live on an always-on-top overlay, with optional translation into a second language shown alongside the original.

Unlike the original, EchoCap downloads no models. It uses the Speech and Translation frameworks that ship with macOS 26, so it works offline the moment you launch it.

| | Subtitles (original) | EchoCap |
|---|---|---|
| Speech recognition | Parakeet / Nemotron (Core ML, 633 MB download) | **macOS Speech framework** (built in, nothing to download) |
| Translation | Apple Translation (on-device) | **Apple Translation** (on-device, same engine) |
| System audio capture | Core Audio process tap | **Core Audio process tap** (same API) |
| Languages | 18 + 2 experimental | Whatever the system has installed (11 measured here) |
| Recognition latency | 160 ms – 2.08 s depending on model | Set by the system model; streaming output measured here |
| Price | $19 one-off | Free and open source |

## Features

**Audio sources**
- Everything the Mac is playing, from any app (including browsers and Electron apps)
- Microphone input
- Switching source clears the captions and resets the recogniser

**Captions**
- Always-on-top overlay that stays above every window
- **Never swallows clicks**, so you can keep working in the app underneath
- **Dissolves under your pointer**, so the text never covers what you are reading or writing
- Hold `⇧` to drag the overlay; the position is remembered
- Broadcast-style paging: fills N lines, then clears and starts over
- Fades about 4 seconds after the last *new* text (not after the audio goes quiet)

**Rewind and search**
- Hold `⌥` to stack the last few caption boxes back above the live one
- `⌥F` searches the history
- `Esc` closes the stack

**Translation**
- Translate into another language and show both at once
- Runs on-device; the translation never leaves the machine

**Also**
- Menu-bar only, no Dock icon
- Transcripts export as plain text, Markdown, or SRT
- Settings panel for size, lines per box, box opacity, dissolve radius, stack spacing, and more — all live

### A failed capture never freezes the app

Core Audio can block when the audio server is unhappy — measured on a machine
whose screen was locked and had no default output device, where
`AudioDeviceStart` simply never returned. So:

- Capture setup happens on its own queue and **never occupies the main thread**,
  so the UI stays responsive
- After an 8-second timeout the app says what went wrong and retries 15
  seconds later — it picks itself up when the machine wakes up
- The message includes an actionable suggestion (for instance, switch to the
  microphone)

## Quick start

```bash
# Build the .app (no Xcode needed)
./build-app.sh

# Run it
open .build/EchoCap.app
```

macOS asks for **Screen & System Audio Recording** permission the first time (required to capture system audio). Grant it and you are set.

### Diagnostic modes

```bash
# Print live recognition and translation to stderr
.build/debug/EchoCap --log --lang en-US --translate zh-Hans

# Render the overlay to a PNG without touching the desktop
.build/debug/EchoCap --render-overlay /tmp/overlay.png
```

## Layout

```
Sources/
  EchoCapCore/            Pure logic, unit tested, no AppKit
    CaptionBox.swift        One caption box
    CaptionPipeline.swift   Paging, history stack, search
    TranscriptAssembler.swift  Cumulative recogniser output → segment events
    SampleRateConverter.swift  48 kHz stereo → 16 kHz mono Int16
    TextMeasurer.swift      CoreText line measurement
    TranscriptExporter.swift  txt / md / srt export
    LanguageCatalog.swift   Language list
    AppSettings.swift       Persisted settings
  EchoCap/                The macOS app
    SystemAudioCapture.swift  Core Audio process tap → aggregate device → IOProc
    SpeechEngine.swift        Streaming macOS Speech recognition
    TranslationService.swift   Apple Translation
    CaptionOverlayWindow.swift Always-on-top overlay window
    CaptionOverlayView.swift   Caption drawing, pointer dissolve, history stack
    MenuBarController.swift    Menu bar
    SettingsWindow.swift       Settings panel
    AppController.swift        Wires the whole pipeline together
Tests/EchoCapTests/       19 unit tests
```

## Technical notes

**Capturing system audio** (`SystemAudioCapture.swift`)

Uses the Core Audio process tap introduced in macOS 14.2. Four steps, matching Apple's reference implementation:

1. `AudioHardwareCreateProcessTap` for a global tap
2. Read its UID via `kAudioTapPropertyUID` (`'tuid'`)
3. Wrap it in a **private aggregate device** (`kAudioAggregateDeviceIsPrivateKey` must be YES) — this is what gives the tap an IO path
4. Attach an IOProc to the aggregate device and read frames

The realtime thread only copies into a lock-free ring buffer; resampling and filtering happen on a worker thread.

> Gotchas: the tap's UID selector is `'tuid'`, not `'uuid'`; the aggregate device's `taps` must be an **array of dictionaries** (`{kAudioSubTapUIDKey: uid}`), not strings; without the `private` key `AudioDeviceStart` returns `'nope'`.

**Audio format** (`SampleRateConverter.swift`)

The Speech framework wants **16 kHz mono Int16 interleaved**. The tap delivers 48 kHz stereo Float32, so the chain is: downmix to mono → 63-tap Blackman-windowed low-pass FIR for anti-aliasing → 3:1 decimation to 16 kHz → Int16.

Note that `AVAudioCommonFormat` raw value 3 is **Int16**, not Float32 — the wrong format crashes inside `AnalyzerInput.init`.

**Segmentation and revisions** (`TranscriptAssembler.swift`)

The Speech framework reports the **cumulative text of the whole current range** on every update, and closes a segment using a *different* range than the one it used while the segment was open — so the range cannot serve as the segment's identity. Segments are instead recognised from the text itself:

- The new text is a prefix of the old → same segment, the recogniser is refining it
- The new and old text share more than 60% of a common prefix → same segment, revised
- Otherwise → a genuinely new utterance; commit the previous one

That way a correction from "EchoCab" to "EchoCap" simply replaces the caption instead of leaving the stale fragment behind forever.

**Concurrency** (Swift 6 strict concurrency)

- Everything touching UI is `@MainActor`
- `TranslationService` is an actor — a `TranslationSession` is stateful and cannot be used concurrently
- Recognition callbacks live in a `SpeechCallbacks` box that the results task reads on every event. An earlier version captured them before `start()` returned, so every result was silently dropped
- Audio flows through `@unchecked Sendable` classes whose isolation is guaranteed by the actor and main queue

## Build notes

This machine has only the Command Line Tools, no full Xcode, so:

- SwiftPM compiles the binary; `build-app.sh` assembles the `.app` by hand and ad-hoc signs it
- Unit tests use Swift Testing (`XCTest` is not in the CLT)
- **SwiftPM does not reliably pass the testing macro plugin to the test target**, so `Package.swift` adds `-plugin-path` explicitly. `swiftLanguageModes: [.v5]` also breaks the testing macros — the package must stay in Swift 6 mode

## Known limitations

- Requires macOS 26 or later (`SpeechAnalyzer` / `SpeechTranscriber`)
- Requires Apple silicon
- System audio capture needs Screen & System Audio Recording permission; **if you deny it macOS reports no error, you just get silence**
- Ad-hoc signing changes the CDHash on every rebuild, so macOS may re-ask for permission; a Developer ID signature avoids this
- Automatic language detection needs the multilingual model (`mul_IN`); when it is not installed the app falls back to an installed single-language model
- Not implemented: automatic new box on speaker change (needs a speaker-diarisation model), speaking the translation aloud, capturing a single named app

## License

MIT
