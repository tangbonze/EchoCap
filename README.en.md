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
- Hold `⇧` to drag the overlay; the position is remembered
- **Nothing starts by itself**: press `⌥⌘S` (or "Start listening" in the menu bar) to begin, and again to pause
- The shortcut is yours to change: Settings → Behaviour → Shortcut, click the field and press the combination you want (must include ⌘, ⌥ or ⌃)
- `⌥⌘L` (or the menu item) turns on layout editing: the window takes clicks, so you can **drag it anywhere** and drag any edge or corner to **resize** it (minimum 360×96). A dashed outline marks the mode; turn it off and the window is click-through again
- **Separate line budgets** for the original and the translation — two each by default. The oldest words scroll off instead of the whole box clearing
- Fades about 4 seconds after the last *new* text (not after the audio goes quiet)

**Which model does what**
- **Speech recognition is always local.** It uses the Speech framework built into macOS; the audio never leaves the machine. There is no cloud option for it.
- **Translation** and **summarising** each have a "local / cloud API" switch, set independently:
  - local: Apple Translation and the on-device Apple Intelligence model
  - cloud: any OpenAI-compatible endpoint (OpenAI, DeepSeek, Moonshot, a local Ollama…). Once the endpoint and key are in, the app asks `/models` and lists what is available — pick from the dropdown. It only falls back to typing a name when the endpoint cannot list them; there is also a "Fetch model list" button.
- The API key is stored in the **system Keychain**, not in the preferences file. Settings has a "Test connection" button.
- Chinese output is folded to Simplified — Apple ships one Chinese model for both scripts and switches between them mid-session.

**A recording asks to be kept**
- Pausing (`⌥⌘S`) or quitting from the menu offers to save the session: how many captions, how long.
- Saving offers **Markdown (.md)** or **plain text (.txt)**, picked in the save dialog
- Choose "summarise with the local model" or "summarise with the cloud API"; whichever cannot run says why
- The summary then goes to the top of the Markdown file and into its own window, ready to copy.
- When the summary model is unavailable the checkbox says why (this Mac does not qualify for Apple Intelligence, for instance) — the cloud engine is the way around it.

**Rewind and search**
- Hold `⌥` to stack the last few caption boxes back above the live one
- `⌥F` searches the history
- `Esc` closes the stack

**Translation**
- Translate into another language and show both at once
- The translation follows the text on screen in near real time (throttled to about 0.3 s, one request at a time) and is re-checked once the sentence settles, so it never trails the original by seconds
- Chinese output is folded to Simplified: Apple ships one Chinese model for both scripts and switches between them mid-session, so every result is normalised
- Runs on-device; the translation never leaves the machine
- Chinese output is folded to Simplified: Apple ships one Chinese model for both scripts and switches between them mid-session, so every result is normalised

**Also**
- Menu-bar only, no Dock icon
- Transcripts export as plain text, Markdown, or SRT
- The menu keeps only what is handy while listening; everything else lives in Settings
- Settings panel for size, original lines, translation lines, box opacity, letter alignment, caption timing, stack spacing, and more — all live

### A failed capture never freezes the app — and it tells you why

System audio is captured by a **separate helper process** (`EchoCapCapture`);
the GUI only reads PCM frames from its standard output.

That split is not cosmetic. `AudioDeviceCreateIOProcID` negotiates stream usage
with the audio server, and that negotiation goes through the run loop. **In a
process that runs an AppKit event loop the call never returns** — it wedges the
UI and never yields audio. A plain command-line process has no such problem,
which is why the helper deliberately does not link AppKit.

So:

- Capture never occupies the main thread, so the UI stays responsive
- After a 10-second timeout a **red banner** appears in the overlay saying
  exactly what went wrong and what to do about it
- The app retries 15 seconds later and picks itself up when audio recovers
- On the way out (⌘Q or `kill`) the tap and aggregate device are destroyed
  first, so nothing is left behind for the audio server to trip over
- The helper also sweeps up aggregate devices left by an earlier run

> If the banner says the macOS audio service may be stuck, `sudo killall
> coreaudiod` or a reboot fixes it. That is a macOS problem, not an EchoCap one.
>
> Another trap: **after a rebuild macOS may silently stop honouring the
> recording permission** — no error, just a tap that starts and delivers pure
> silence. So if there is neither text nor any signal (peak ≈ 0) within six
> seconds, the overlay says so; re-allow EchoCap under System Settings →
> Privacy & Security → Screen & System Audio Recording.

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
  EchoCapCapture/         Capture helper (no GUI, runs the tap in its own process)
  EchoCap/                The macOS app
    HelperAudioCapture.swift   Drives the capture helper, reads PCM frames
    CaptureHelper.swift        The helper: Core Audio process tap → aggregate device → IOProc
    SpeechEngine.swift        Streaming macOS Speech recognition
    TranslationService.swift   Apple Translation
    CaptionOverlayWindow.swift Always-on-top overlay window
    CaptionOverlayView.swift   Caption drawing, history stack
    MenuBarController.swift    Menu bar
    SettingsWindow.swift       Settings panel
    AppController.swift        Wires the whole pipeline together
Tests/EchoCapTests/       19 unit tests
```

## Technical notes

**Capturing system audio** (`EchoCapCapture/` + `HelperAudioCapture.swift`)

Uses the Core Audio process tap introduced in macOS 14.2. Four steps, matching Apple's reference implementation:

1. `AudioHardwareCreateProcessTap` for a global tap
2. Read its UID via `kAudioTapPropertyUID` (`'tuid'`)
3. Wrap it in a **private aggregate device** (`kAudioAggregateDeviceIsPrivateKey` must be YES) — this is what gives the tap an IO path
4. Attach an IOProc to the aggregate device and read frames

The realtime thread only copies into a lock-free ring buffer; resampling and filtering happen on a worker thread.

The helper writes 16 kHz mono Int16 PCM to its standard output, framed as a
4-byte little-endian length followed by that many bytes. The GUI reads those
frames and feeds them straight to the recogniser.

> Gotchas, all measured:
>
> - The tap's UID selector is `'tuid'`, not `'uuid'`
> - The aggregate device's `taps` must be an **array of dictionaries**
>   (`{kAudioSubTapUIDKey: uid}`), not strings
> - Without the `private` key `AudioDeviceStart` returns `'nope'`
> - `AudioDeviceCreateIOProcID`'s **client data must be nil** — a non-nil
>   pointer leaves the handshake waiting forever
> - The callback has to be a **plain global function**, not a closure literal:
>   Swift bridges a closure to a C function pointer through a context, and the
>   audio server never completes the handshake with one
> - **A tap cannot be created in a process running an AppKit run loop** — hence
>   the separate helper
> - For a window with `isOpaque = false`, the root view's background **must not
>   be `Color.clear`**: with nothing to composite, SwiftUI's `.mask` renders the
>   whole layer as nothing and not a single caption shows. Use a
>   near-invisible plate such as `Color.black.opacity(0.004)`
> - Do not set `contentView.translatesAutoresizingMaskIntoConstraints` to
>   `false`, and do not constrain the hosting view to `contentView` — the
>   content view collapses to zero size and draws nothing

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
- Screen & System Audio Recording permission is required. Creating the tap
  blocks while macOS shows the prompt, so the app waits up to 90 seconds and
  says so in the overlay
- A caption fades about 4 seconds after the speech stops (tune `fadeDelay` in
  Settings); hold `⌥` to bring the history back; the helper lives inside the app bundle and shares the app's grant

## License

MIT
