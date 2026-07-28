# Cheerio — Claude Code handoff

Open-source, single-user Granola alternative. macOS-first, local-only: SpeechAnalyzer/SpeechTranscriber for transcription, Foundation Models for summaries, Core Audio process taps for system audio. Read `docs/SPEC.md` (scope) and `docs/ARCHITECTURE.md` (design + gotchas) before changing anything.

## State of the repo

Scaffold only — **never compiled**. It was written in a sandbox without a Swift toolchain, from API docs. Expect compiler errors on first build; fixing them is the first task.

- `CheerioKit/` — SwiftPM package: SwiftData models, `TranscriptionEngine` (actor per audio channel), `SummarizationEngine` (map-reduce over ~4k-token on-device context), `CalendarService`. Has a small Swift Testing test target.
- `Cheerio/` — macOS app target: `MicrophoneCapture` (AVAudioEngine), `SystemAudioTap` (CATap → aggregate device → IOProc), `CaptureSession` (@Observable orchestrator), SwiftUI views.
- No `.xcodeproj` committed — generated via XcodeGen from `project.yml`.

## Build

```sh
brew install xcodegen   # if needed
xcodegen generate
open Cheerio.xcodeproj  # scheme: Cheerio
```

Requires macOS 26+, Xcode 26+. Package tests: `cd CheerioKit && swift test`.

## Immediate tasks (in order)

1. `xcodegen generate` + first build; fix compiler errors. Most-suspect spots:
   - `TranscriptionEngine.emit` — verify `SpeechTranscriber.Result` property names (`text`, `isFinal`, time range; I used `result.range: CMTimeRange`).
   - `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` call shape.
   - `SystemAudioTap` — CoreAudio constant names (`kAudioTapPropertyFormat`, `kAudioAggregateDeviceTapListKey`, `kAudioSubTapUIDKey`) and `AVAudioPCMBuffer(pcmFormat:bufferListNoCopy:deallocator:)`.
   - Swift 6 strict concurrency complaints around the `@unchecked Sendable` audio classes and buffer hand-off.
2. Run it: record a Zoom/Meet call, confirm both Me/Them channels transcribe live.
3. Wire `CalendarService` into `MeetingListView.startRecording()` (TODO marker there) — use current event for title/eventID.
4. Audio-to-disk recording (CAF) + retention setting — designed in ARCHITECTURE.md, not implemented.
5. Search in the meeting library; Markdown export exists on detail view already.

## Conventions & constraints

- Local-only by construction: **no network entitlement, ever**. No analytics, no accounts.
- Anything portable to iOS lives in `CheerioKit`; Core Audio tap code stays in the app target.
- Realtime audio callbacks do no work — hand buffers off immediately (AsyncStream/Task).
- Two transcription engines (mic/system) instead of diarization — that's deliberate; don't merge streams.
- Swift 6, strict concurrency complete. SwiftData for storage. MIT licensed.
- Bundle prefix `app.cheerio` is a placeholder (`project.yml` TODO).

## Reference

- AVAudioEngine **cannot** read a tap-backed aggregate device — raw IOProc only (see ARCHITECTURE.md).
- Working tap examples: github.com/makeusabrew/audiotee and the CATap gist by directmusic.
- WWDC26 `LanguageModel` protocol makes summarization models pluggable — v2, keep `SummarizationEngine`'s model injectable when touching it.
