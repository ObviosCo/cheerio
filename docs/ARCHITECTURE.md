# Cheerio — Architecture

## Layout

```
cheerio/
├── project.yml          # XcodeGen config → generates Cheerio.xcodeproj
├── CheerioKit/          # SwiftPM package: platform-portable core (macOS + future iOS)
│   └── Sources/CheerioKit/
│       ├── Models/          # SwiftData models: Meeting, TranscriptSegment
│       ├── Transcription/   # SpeechAnalyzer/SpeechTranscriber wrapper
│       ├── Summarization/   # Foundation Models wrapper + @Generable output types
│       └── Calendar/        # EventKit wrapper
└── Cheerio/             # macOS app target
    ├── Audio/           # Mic capture, Core Audio process tap, capture session
    └── Views/           # SwiftUI
```

Rule: anything that could run on iOS goes in `CheerioKit`. System-audio capture is macOS-only Core Audio, so it lives in the app target.

## Audio pipeline

Two independent streams, transcribed separately — this is how we get Me/Them labels without diarization:

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

## Summarization

`SummarizationEngine` wraps `LanguageModelSession` (FoundationModels):

- Output types are `@Generable` structs (`EnhancedNotes`, `ActionItem`) — type-checked, no JSON parsing
- The on-device model's context window is small (~4k tokens). Long meetings use map-reduce: transcript → ~10-min chunks → chunk summaries → final merge pass that also folds in the user's rough notes
- Check `SystemLanguageModel.default.availability` and degrade gracefully (transcript-only mode)
- v2: swap models via the WWDC26 `LanguageModel` protocol — the engine takes the model as a dependency

## Storage

SwiftData, single local store. `Meeting` (title, times, event ID, rough notes, enhanced notes) 1-many `TranscriptSegment` (speaker channel, text, time range). Audio files in Application Support, referenced by path, subject to retention policy.

## Concurrency

Swift 6 strict concurrency. Audio IOProcs/taps hand buffers off through `AsyncStream` immediately — no work on the realtime thread. Engines are actors; UI observes `@Observable` view models on `@MainActor`.

## Permissions & entitlements

**App Sandbox off — do not turn it back on.** A sandboxed process tap is created with `noErr` at every step and then reads pure digital silence: no TCC prompt, no error anywhere, and it presents exactly like a transcription bug. Measured on identical code, `peak=0.0` sandboxed against `-1.8 dBFS` unsandboxed. `SystemAudioTap`'s `SilenceWatch` logs the verdict at `.notice`/`.error` on stop, which is the quickest way to recognise it. This rules out Mac App Store distribution. Hardened runtime stays on.

`com.apple.security.device.audio-input`, `com.apple.security.personal-information.calendars`. Usage strings: mic, audio capture, calendar. No network entitlement — enforced local-only by construction.
