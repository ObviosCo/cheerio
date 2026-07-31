# Cheerio — Claude Code handoff

Open-source, single-user Granola alternative. macOS-first, local-only: SpeechAnalyzer/SpeechTranscriber for transcription, Foundation Models for summaries, Core Audio process taps for system audio. Read `docs/SPEC.md` (scope) and `docs/ARCHITECTURE.md` (design + gotchas) before changing anything.

## State of the repo

Builds clean (no warnings), package tests pass, and the app launches and stays up. **Not yet verified against a live call** — see task 1 below.

Speaker differentiation *is* verified for in-person meetings: on 2026-07-31, with Jackson and Carter both enrolled, a 51s two-person recording labelled 9/9 segments correctly — including 1–2s alternating turns — against narrated ground truth. `them.caf` measured −90 dBFS (silent) for that meeting, so all of it came from Sortformer, none from the channel split.

- `CheerioKit/` — SwiftPM package: SwiftData models, `TranscriptionEngine` (actor per audio channel), `SummarizationEngine` (map-reduce over ~4k-token on-device context), `CalendarService`, `MeetingAudioRecorder` + retention policy, `SpeakerAttributionService` (diarization). Swift Testing target covers buffer copying, CAF writing, retention math, search, and overlap-based speaker labelling.
- One third-party dependency: **FluidAudio** (Apache-2.0), pinned exactly. Wraps Sortformer on Core ML/ANE for speaker diarization, because `SpeechTranscriber` has no speaker surface at all. Sortformer resolves **at most 4 speakers**.
- `Cheerio/` — macOS app target: `MicrophoneCapture` (AVAudioEngine), `SystemAudioTap` (CATap → aggregate device → IOProc), `CaptureSession` (@Observable orchestrator), SwiftUI views incl. Settings.
- No `.xcodeproj` committed — generated via XcodeGen from `project.yml`. **Re-run `xcodegen generate` after adding files**, or the build won't see them.

## Build

```sh
brew install xcodegen     # if needed
./Scripts/fetch-models.sh # ~93 MB diarization model, not committed
xcodegen generate
open Cheerio.xcodeproj    # scheme: Cheerio
```

Requires macOS 26+, Xcode 26+. Package tests: `cd CheerioKit && swift test`.

The fetch script is idempotent, checksum-verified, and also runs as a pre-build
phase — but `xcodegen generate` needs the model directory to already exist, so run
it first on a fresh clone. The model is licensed under the **NVIDIA Open Model
License**, not MIT; keeping it out of the repo keeps the source tree MIT while the
built app ships an NVIDIA-licensed model.

## Immediate tasks

1. **Mic picks up the speakers.** Verified end to end on 2026-07-28: both channels transcribe, notes generate, both CAFs write. But with audio on speakers the mic also hears it, so system audio lands in *both* channels and the transcript duplicates itself — which then skews the summary. Fix is almost certainly `AVAudioEngine.inputNode.setVoiceProcessingEnabled(true)` in `MicrophoneCapture` for acoustic echo cancellation; note it can throw and can change the input format, so re-verify the mic path after enabling.

   **App Sandbox must stay off.** A sandboxed build creates the tap with `noErr` at every step and then reads pure digital silence, with no TCC prompt — it looks like a transcription bug but it's a capture-permission failure. Measured: `peak=0.0` sandboxed vs `-1.8 dBFS` unsandboxed, same code. This rules out Mac App Store distribution. `SystemAudioTap`'s `SilenceWatch` logs the verdict at `.notice`/`.error` on stop (`.info` never reaches `log show`).
2. **Live transcript shows channels, not names.** `RecordingView.transcriptLine` renders `Me`/`Them` off `line.channel`; diarization is a post-pass over the CAF files, so names only land once the recording stops. In a local meeting everyone is on the mic, so *every* live line reads "Me" — which looks like a differentiation failure and isn't. Names during capture would mean running Sortformer streaming alongside the engines rather than after them.
3. Enrollment is up-front only: `ParticipantsView` records a fresh ~20s sample, i.e. you have to ask someone to talk into your Mac. Retroactive is the better UX — label a diarized turn in a finished meeting and save that slice as the reference clip. `SpeakerAttributionService` already takes any audio file, so this is UI-only work.

4. Calendar is read-only: SPEC goal 5 also wants "suggest recording when a meeting starts" and "attach notes to the event". Neither is implemented — `calendarEventID` is stored but never used afterward.

5. `RecordingMode` (solo / in-person / video call) was designed but not built. It matters because the system tap is pointless for solo and in-person work, and mic voice processing should differ per mode: AEC on for video calls to kill speaker bleed, and `voiceProcessingAGCEnabled` is a separate toggle from AEC (an earlier note here wrongly conflated them).
6. `SummarizationEngine.chunked` splits on a character budget; a single line longer than the budget still goes through whole, and an over-long first line appends an empty chunk.
7. Playback of retained audio — files are written and purged but there's no UI to hear them.

## Conventions & constraints

- Local-only by construction: **no network entitlement, ever**. No analytics, no accounts.
- Anything portable to iOS lives in `CheerioKit`; Core Audio tap code stays in the app target.
- Realtime audio callbacks do no work — hand buffers off immediately (AsyncStream/Task).
- Two transcription engines (mic/system) for the Me/Them split — that's deliberate; don't merge streams. Diarization sits *on top* of them, per-channel, to tell people apart within one channel.
- Swift 6, strict concurrency complete. SwiftData for storage. MIT licensed.
- Bundle prefix `app.cheerio` is a placeholder (`project.yml` TODO).

## Reference

- AVAudioEngine **cannot** read a tap-backed aggregate device — raw IOProc only (see ARCHITECTURE.md).
- Working tap examples: github.com/makeusabrew/audiotee and the CATap gist by directmusic.
- WWDC26 `LanguageModel` protocol makes summarization models pluggable — v2, keep `SummarizationEngine`'s model injectable when touching it.
