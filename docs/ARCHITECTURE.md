# Cheerio — Architecture

## Layout

```
cheerio/
├── project.yml          # XcodeGen config → generates Cheerio.xcodeproj
├── Scripts/             # bootstrap.sh (fresh checkout → buildable), fetch-models.sh
├── CheerioKit/          # SwiftPM package: platform-portable core (macOS + future iOS)
│   └── Sources/CheerioKit/
│       ├── Models/          # SwiftData models: Meeting, TranscriptSegment, EnrolledSpeaker
│       ├── Audio/           # CAF recording, retention policy, excerpts, storage paths
│       ├── Transcription/   # SpeechAnalyzer/SpeechTranscriber wrapper
│       ├── Diarization/     # SpeakerAttributionService — Sortformer via FluidAudio
│       ├── Summarization/   # Foundation Models wrapper + @Generable output types
│       └── Calendar/        # EventKit wrapper
└── Cheerio/             # macOS app target
    ├── Audio/           # Mic capture, Core Audio process tap, capture session, labelling
    ├── Resources/       # Models/ — fetched at build time, never committed
    └── Views/           # SwiftUI
```

Rule: anything that could run on iOS goes in `CheerioKit`. System-audio capture is macOS-only Core Audio, so it lives in the app target.

## Dependencies

One third-party package: **FluidAudio** (Apache-2.0), pinned to an exact version. It wraps NVIDIA's Sortformer diarization model for Core ML / the Neural Engine.

The model itself (~93 MB) is not committed. `Scripts/fetch-models.sh` downloads it against pinned SHA-256 hashes and also runs as a pre-build phase. The model carries the **NVIDIA Open Model License**, not MIT: keeping it out of the tree is what lets the source stay MIT while a built app ships an NVIDIA-licensed model.

`Scripts/bootstrap.sh` is what a fresh checkout should run — it verifies the toolchain, fetches the model, and generates the project in that order. The order is load-bearing: `project.yml` references the `.mlmodelc` as a folder reference, so `xcodegen generate` refuses to write a project until the model is on disk, and the pre-build phase can't cover that gap because there's no project yet to hang a phase on.

It is fetched at *build* time, never at runtime. Cheerio has no networking code, so a runtime download is not an option available to it.

## Audio pipeline

Two independent streams, transcribed separately. The split is what produces Me/Them labels, with no model involved — diarization then sits *on top* of it, per channel, to tell individual people apart within one stream:

```
Mic ──── AVAudioEngine.inputNode tap ──► TranscriptionEngine("Me")
System ── CATap → aggregate device → IOProc ──► TranscriptionEngine("Them")
```

**System audio (macOS):** `CATapDescription(stereoGlobalTapButExcludeProcesses: [])` → `AudioHardwareCreateProcessTap` → wrap in an aggregate device → `AudioDeviceCreateIOProcIDWithBlock`. Requires the audio-capture TCC prompt (`NSAudioCaptureUsageDescription`).

> Gotcha: AVAudioEngine cannot be pointed at a tap-backed aggregate device. Use a raw IOProc and convert `AudioBufferList` → `AVAudioPCMBuffer` manually.

**Mic:** plain `AVAudioEngine` input tap. Portable to iOS as-is.

Each stream is converted (`AVAudioConverter`) to `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` before feeding the analyzer. Raw audio is also written to disk (CAF) so transcription failures aren't fatal; retention is a setting.

## Transcription

`TranscriptionEngine` (one instance per stream):

- `SpeechTranscriber(locale:…, reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])`
- `SpeechAnalyzer(modules: [transcriber])` fed via `AsyncStream<AnalyzerInput>`
- Volatile results drive the live-transcript UI; final results become persisted `TranscriptSegment`s
- First-run model install: `AssetInventory.assetInstallationRequest(supporting:)` with download progress surfaced in UI

## Diarization

`SpeakerAttributionService` (actor) separates speakers *within* one recorded channel. It exists because `SpeechTranscriber` exposes no speaker information whatsoever — the channel split gives Me vs Them and nothing finer, which is useless for three people in a room or two participants on one Zoom connection.

- Runs as a **post-pass over the CAF files**, not during capture. It therefore has to run *before* the retention policy purges them.
- Enrolled voices (`EnrolledSpeaker`) prime the model so turns come back as names rather than "Speaker 2". Sortformer is primed by *processing* the enrollment audio before each meeting, not by storing an embedding — which is why the reference recordings must be kept on disk.
- Enrollment samples need **≥ 30s**. Measured on 2026-08-03: a 23.6s sample still let Sortformer split one person across two speaker slots mid-meeting, while 26.5s and 27.8s samples held. The earlier 20s guidance was too optimistic.
- **Sortformer resolves at most 4 speakers** per channel. Past that, voices merge into existing slots; `SpeakerLabeling` reports who it left out rather than truncating silently. `isMe` is kept first when the cap has to drop someone.
- Labels are scoped per channel, so "Speaker 2" on the mic and "Speaker 2" on the system tap are never merged. The "me" voice is dropped from the system-tap channel — you can't be on the far end of your own call.
- Manual corrections (`TranscriptSegment.isSpeakerLabelManual`) outrank the model and survive re-runs.

> Gotcha: because this is a post-pass, the *live* transcript can only show Me/Them. In an in-person meeting everyone is on the mic, so every live line reads "Me" until the recording stops. That looks like a differentiation failure and isn't. Naming during capture would mean running Sortformer streaming alongside the engines instead of after them.

## Summarization

`SummarizationEngine` wraps `LanguageModelSession` (FoundationModels):

- Output types are `@Generable` structs (`EnhancedNotes`, `ActionItem`) — type-checked, no JSON parsing
- The on-device model's context window is small (~4k tokens). Long meetings use map-reduce: transcript → ~10-min chunks → chunk summaries → final merge pass that also folds in the user's rough notes
- Check `SystemLanguageModel.default.availability` and degrade gracefully (transcript-only mode)
- v2: swap models via the WWDC26 `LanguageModel` protocol — the engine takes the model as a dependency

## Storage

SwiftData, single local store. `Meeting` (title, times, event ID, rough notes, enhanced notes, per-meeting participant roster) 1-many `TranscriptSegment` (speaker channel, text, time range, resolved speaker label, and whether that label was set by hand). `EnrolledSpeaker` holds a known voice: name, reference-audio path, duration, and an `isMe` flag.

Audio lives in Application Support, referenced by path, one CAF per channel per meeting. `AudioRetention` purges it on a schedule — immediately, 24 hours, 7 days, 30 days, or never — defaulting to 7 days. Transcripts and notes are never touched by retention; only the raw audio.

Note the data location moves with the sandbox flag: a sandboxed build would live under `~/Library/Containers/app.cheerio.mac/Data/`, an unsandboxed one under `~/Library`. Since the sandbox is off (below), it's the latter.

## Concurrency

Swift 6 strict concurrency. Audio IOProcs/taps hand buffers off through `AsyncStream` immediately — no work on the realtime thread. Engines are actors; UI observes `@Observable` view models on `@MainActor`.

## Permissions & entitlements

**App Sandbox off — do not turn it back on.** A sandboxed process tap is created with `noErr` at every step and then reads pure digital silence: no TCC prompt, no error anywhere, and it presents exactly like a transcription bug. Measured on identical code, `peak=0.0` sandboxed against `-1.8 dBFS` unsandboxed. `SystemAudioTap`'s `SilenceWatch` logs the verdict at `.notice`/`.error` on stop, which is the quickest way to recognise it. This rules out Mac App Store distribution. Hardened runtime stays on.

`com.apple.security.device.audio-input`, `com.apple.security.personal-information.calendars`. Usage strings: mic, audio capture, calendar. No network entitlement.

One consequence of the sandbox being off: the missing network entitlement no longer *enforces* anything — entitlements only constrain a sandboxed process. Local-only now rests entirely on there being **no networking code in the app at all**: no `URLSession`, no sockets, nothing. That is the invariant to protect in review; the entitlement is now a statement of intent rather than a guarantee. The diarization model is fetched by a build script, which is why runtime networking is never needed.
