# Cheerio

Open-source AI meeting notes for macOS. Like Granola, but single-user, local-only, and free.

Cheerio records both sides of a meeting straight off your Mac's audio hardware, transcribes it
on-device, tells the participants apart by name, and merges the transcript with the rough notes
you typed during the call into structured enhanced notes. No bot joins your call. Nothing leaves
the machine.

> **Status: works, lightly tested.** The app builds and runs, 47 package tests pass, and
> speaker differentiation is verified for in-person meetings. It has **not** been verified
> against a live video call yet, and there is a known echo problem when you use speakers
> instead of headphones. See [Current status](#current-status).

## Why

Granola-style meeting notes are excellent and require shipping your meetings to someone else's
servers on a subscription. As of macOS 26, Apple ships nearly everything needed to do it
locally: `SpeechAnalyzer`/`SpeechTranscriber` for transcription, the Foundation Models framework
for summarization, and Core Audio process taps for system audio. Cheerio is that, assembled —
plus one on-device model Apple doesn't provide, for telling speakers apart.

## What it does

- **Capture without bots.** Microphone (you) and system audio (everyone else) are captured as
  two independent streams via Core Audio process taps. Works with Zoom, Meet, Teams, or anything
  else that makes sound — no meeting bot, no calendar-service integration, no participants list
  to manage.
- **Transcribe on-device.** Each stream gets its own `SpeechTranscriber`, which is where the
  `Me` / `Them` split comes from. Live volatile results drive the in-meeting transcript; final
  results are persisted with timestamps.
- **Tell people apart by name.** The channel split can't distinguish three people in one room,
  and `SpeechTranscriber` exposes no speaker information at all. So a Sortformer diarization
  pass runs over the recorded audio after the meeting. Enroll a voice once and it comes back
  named instead of "Speaker 2"; pick who was in a given meeting from a per-meeting roster; fix
  any label by hand, and your correction outranks the model.
- **Rough notes are first-class.** A scratchpad sits next to the live transcript during the
  meeting. What you bothered to type is the strongest signal about what mattered.
- **Enhance locally.** Afterwards the on-device Foundation Model merges your rough notes with
  the transcript into a summary, key points, decisions, and action items. Long meetings are
  handled map-reduce style to fit the model's ~4k-token context window.
- **Calendar-aware, optionally.** EventKit supplies the current event to title a recording and
  link it back. Denying calendar access costs you only the convenience.
- **Library, search, and export.** Browse past meetings, search across titles, notes,
  transcripts, and speaker names, and export any meeting as Markdown.
- **Audio retention you control.** Raw audio is written to disk per channel so a transcription
  failure isn't fatal, then purged on your schedule — discard immediately, 24 hours, 7 days,
  30 days, or keep forever. The default is 7 days.

Full scope and non-goals: [`docs/SPEC.md`](docs/SPEC.md).

## Local-only by construction

- **There is no networking code in the app.** No `URLSession`, no sockets, nothing. That is the
  actual guarantee, and it is worth stating precisely: because App Sandbox is off (see below),
  entitlements no longer *enforce* the boundary — the absence of networking code is what does.
- **Both models run on-device.** Speech and summarization use Apple's local models; diarization
  runs the bundled Sortformer model on the Neural Engine. The diarization model is downloaded
  at *build* time by a script, never at runtime.
- No accounts, no telemetry, no analytics, no crash reporting.
- The only network activity the app can cause is macOS itself fetching the speech model for
  your locale on first run.

## Requirements

- macOS 26 (Tahoe) or later, Apple Silicon
- Xcode 26 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

The `.xcodeproj` is generated, not committed; `project.yml` is the source of truth.

## Building

```sh
git clone https://github.com/ObviosCo/cheerio.git && cd cheerio
```

```sh
./Scripts/bootstrap.sh
```

```sh
open Cheerio.xcodeproj
```

Then build and run the `Cheerio` scheme.

`bootstrap.sh` checks that XcodeGen is installed and that a full Xcode is selected, downloads
the ~93 MB Sortformer diarization model (not committed to the repo), and generates the Xcode
project — in that order, which matters: `project.yml` references the model as a folder
reference, so `xcodegen generate` fails on a fresh clone if the model isn't there yet. Every
step is idempotent, so re-running it is cheap.

Re-run it after adding or removing source files, or the build won't see them.

To build from the command line:

```sh
xcodebuild -project Cheerio.xcodeproj -scheme Cheerio -configuration Debug build
```

### The package on its own

`CheerioKit` is a SwiftPM package and builds without Xcode's project machinery:

```sh
cd CheerioKit && swift test
```

`swift build` needs a full Xcode selected via `xcode-select` — the Command Line Tools alone ship
the SDK but not the SwiftData and FoundationModels macro plugins, and the build fails on missing
macros.

### Before you run it

- **Set your bundle identifier.** `project.yml` uses the placeholder prefix `app.cheerio`.
- **First launch downloads a speech model.** macOS fetches the `SpeechTranscriber` assets for
  your locale once, per locale.
- **Enroll your voice in Settings.** Diarization returns names only for voices it has heard
  before. Samples need **at least 30 seconds** — shorter ones measurably cause the model to
  split one person across two speaker slots.
- **Use headphones.** See the echo issue below.

## Current status

Verified against this commit on macOS 27 / Xcode 26:

| Check | Result |
|---|---|
| `CheerioKit` tests | 47 tests, 8 suites, all pass |
| `Cheerio` app build | succeeds (2 warnings) |
| End-to-end capture | verified 2026-07-28 — both channels transcribe, notes generate, both CAFs write |
| Speaker differentiation, in person | verified 2026-07-31 — 9/9 segments labelled correctly across 1–2s alternating turns |
| Live video call | **not yet verified** |

Known issues, roughly in priority order:

- **The mic hears your speakers.** With meeting audio playing out loud, system audio lands in
  *both* channels and the transcript duplicates itself, which then skews the summary. Use
  headphones until acoustic echo cancellation is enabled on the mic input.
- **The live transcript shows `Me` / `Them`, not names.** Diarization is a post-pass over the
  recorded files, so names appear only once the recording stops. In an in-person meeting
  everyone is on the mic, so every live line reads "Me" — this looks like a differentiation
  failure and isn't.
- **At most four speakers per channel.** A hard limit of the Sortformer model. Beyond four,
  voices get merged into existing slots; the app tells you who it left out rather than
  truncating silently.
- **In-room vs. remote isn't modelled.** Nothing records which side of the call a participant
  was on, so each one is primed against both channels and can burn a speaker slot on the wrong
  one.
- **Calendar is read-only.** Recordings get their title and event ID from the current event, but
  "suggest recording when a meeting starts" and "attach notes back to the event" aren't built.
- **No playback.** Retained audio is written and purged but there's no UI to listen to it.

**No Mac App Store.** App Sandbox has to stay off: a sandboxed process tap is created with
`noErr` at every step and then reads pure digital silence, with no permission prompt and no
error anywhere. Measured on identical code: `peak=0.0` sandboxed against `-1.8 dBFS`
unsandboxed. Hardened runtime stays on.

## Project layout

```
cheerio/
├── project.yml       # XcodeGen config → generates Cheerio.xcodeproj
├── Scripts/          # bootstrap.sh — fresh checkout → buildable, in one command
├── CheerioKit/       # SwiftPM package: portable core (macOS + future iOS)
│   └── Sources/CheerioKit/
│       ├── Models/           # SwiftData: Meeting, TranscriptSegment, EnrolledSpeaker
│       ├── Audio/            # CAF recording, retention, excerpts, storage
│       ├── Transcription/    # SpeechAnalyzer/SpeechTranscriber wrapper
│       ├── Diarization/      # Sortformer speaker attribution
│       ├── Summarization/    # Foundation Models wrapper, @Generable output
│       └── Calendar/         # EventKit wrapper
└── Cheerio/          # macOS app target
    ├── Audio/        # Mic capture, Core Audio process tap, capture session
    ├── Resources/    # Models/ — fetched, never committed
    └── Views/        # SwiftUI
```

The rule: anything that could run on iOS lives in `CheerioKit`. System-audio capture is
macOS-only Core Audio, so it stays in the app target.

Design notes and the gotchas worth knowing before you touch the audio path:
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Roadmap

Near-term: acoustic echo cancellation on the mic, verification against a live video call, a
recording mode (solo / in-person / video call) so the system tap isn't started when it's
pointless, an in-room vs. remote toggle per participant, and playback of retained audio.

Later: an iOS app for in-person meetings, pluggable summarization models via the `LanguageModel`
protocol, semantic search, and Obsidian folder auto-export.

## Contributing

Issues and pull requests are welcome. Two constraints are not up for negotiation: **no
networking code and no network entitlement, ever**, and no analytics or accounts. Beyond that,
keep portable logic in `CheerioKit`, do no work on realtime audio callbacks, and leave strict
concurrency on.

## License

Cheerio itself is MIT — see [LICENSE](LICENSE).

Two things it depends on are not:

- **FluidAudio** (Apache-2.0), the Swift wrapper around Sortformer.
- **NVIDIA Sortformer v2.1**, the diarization model, under the
  [NVIDIA Open Model License](https://huggingface.co/FluidInference/diar-streaming-sortformer-coreml).
  It is deliberately not committed to this repo — that keeps the source tree MIT, while an app
  you build from it bundles an NVIDIA-licensed model. Check that license before redistributing
  a build.
