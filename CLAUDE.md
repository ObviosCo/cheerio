# Cheerio — Claude Code handoff

Open-source, single-user macOS app that turns meetings into AI-actionable transcripts. Local
models are how it does that without a subscription or a third-party service: SpeechAnalyzer/
SpeechTranscriber for transcription, Foundation Models for summaries, Core Audio process taps
for system audio. Read `docs/SPEC.md` (scope) and `docs/ARCHITECTURE.md` (design + gotchas)
before changing anything.

**Pivot in progress:** Cheerio's identity is "transcripts AI agents act on," not "meeting notes
that never touch the network" — local-only is what makes it free of a third-party service and a
subscription, not the point of the app. See the tracking epic,
[#22](https://github.com/ObviosCo/cheerio/issues/22), and its PR stack. The agent-facing
surfaces this framing implies — MCP server, transcript-ready callback, directive mode,
owner-attributed action items — are scoped in that stack; check `gh issue list` before assuming
any of them exist yet, since docs describing the goal land ahead of the code that does it.

## State of the repo

Builds and runs; 47 package tests across 8 suites pass. **Not yet verified against a live call** — see issue #5.

Two build warnings remain, both `Binding<Optional<Wrapped>>` captured in a `@Sendable` closure in `Views/Binding+Presented.swift`.

Speaker differentiation *is* verified for in-person meetings: on 2026-07-31, with Jackson and Carter both enrolled, a 51s two-person recording labelled 9/9 segments correctly — including 1–2s alternating turns — against narrated ground truth. `them.caf` measured −90 dBFS (silent) for that meeting, so all of it came from Sortformer, none from the channel split.

- `CheerioKit/` — SwiftPM package: SwiftData models, `TranscriptionEngine` (actor per audio channel), `SummarizationEngine` (map-reduce over ~4k-token on-device context), `CalendarService`, `MeetingAudioRecorder` + retention policy, `SpeakerAttributionService` (diarization). Swift Testing target covers buffer copying, CAF writing, retention math, search, and overlap-based speaker labelling.
- Two third-party dependencies, both pinned exactly (the convention, not an accident):
  - **FluidAudio** (Apache-2.0), in `CheerioKit`. Wraps Sortformer on Core ML/ANE for speaker diarization, because `SpeechTranscriber` has no speaker surface at all. Sortformer resolves **at most 4 speakers**.
  - **Sparkle 2** (MIT), on the app target only — declared in `project.yml`, not `Package.swift`, so both SwiftPM cache keys in CI hash `project.yml` too. Automatic updates; see `Cheerio/Updates/AppUpdater.swift` and the network bullet below.
- `Cheerio/` — macOS app target: `MicrophoneCapture` (AVAudioEngine), `SystemAudioTap` (CATap → aggregate device → IOProc), `CaptureSession` (@Observable orchestrator), `AppUpdater` (Sparkle), SwiftUI views incl. Settings.
- No `.xcodeproj` committed — generated via XcodeGen from `project.yml`. **Re-run `xcodegen generate` after adding files**, or the build won't see them.

## Build

```sh
brew install xcodegen     # if needed
./Scripts/bootstrap.sh    # checks tooling, fetches the model, generates the project
open Cheerio.xcodeproj    # scheme: Cheerio
```

Requires macOS 26+, Xcode 26+. Package tests: `cd CheerioKit && swift test`.

`bootstrap.sh` wraps `fetch-models.sh` + `xcodegen generate` because the order is
load-bearing: `project.yml` references the `.mlmodelc` as a folder reference, so
generating before the model exists fails with a spec-validation error that names a
file you've never heard of. The pre-build phase can't save you there — you can't get
a build phase without a project. Both steps are idempotent; re-run after adding or
removing files. The model is **CC BY 4.0** (© NVIDIA; Core ML conversion by
FluidInference), not MIT — redistribution is fine with the attribution in
`THIRD-PARTY-NOTICES.md`, which is bundled into the app. It's kept out of the repo
because it's ~93 MB, not because the license requires it.

## Tasks

**Tasks live in GitHub issues, not in this file.** `gh issue list` is the current
list; don't add a to-do section back here.

The two worth knowing before you touch the audio path: **#5** (the mic hears your
speakers, so calls transcribe twice — the one issue blocking real use on a video
call) and **#9** (the live transcript can only show Me/Them, which looks like a
bug and isn't).

## Conventions & constraints

- **App Sandbox must stay off.** A sandboxed build creates the tap with `noErr` at every step and then reads pure digital silence, with no TCC prompt — it looks like a transcription bug but it's a capture-permission failure. Measured: `peak=0.0` sandboxed vs `-1.8 dBFS` unsandboxed, same code. This rules out Mac App Store distribution. `SystemAudioTap`'s `SilenceWatch` logs the verdict at `.notice`/`.error` on stop (`.info` never reaches `log show`).
- **Both capture channels run in every recording mode.** Input and output can be different devices, so a solo recording through AirPods still has system audio worth keeping. `RecordingMode` (#12) drives echo cancellation, never whether the tap starts.
- **What "no third-party service" means mechanically:** nothing may need the network while recording or processing a meeting. That invariant is unchanged and still the thing to protect in review — but the app is no longer free of networking code. Sparkle fetches the appcast and, if accepted, an update zip — both assets of Cheerio's own GitHub Releases — and `UpdatePolicy` in `Cheerio/Updates/AppUpdater.swift` refuses *every* check start — scheduled or user-initiated — while `CaptureSession.state != .idle` (a download admitted while idle isn't aborted mid-cycle; documented edge, not machinery). With the sandbox off nothing enforces any of this, so review is the enforcement: capture and processing must stay free of `URLSession`, sockets, and `import Network`, and Sparkle must stay the only thing that talks to the network at all. A one-time download at install/setup (e.g. fetching a model) would also be acceptable; a network dependency during capture never is. Sparkle's system profile stays off — no analytics, no accounts. This isn't air-gapping for its own sake — it's the mechanical form of "no subscription, no third party." It doesn't rule out local surfaces for other processes on the same machine: a future MCP server speaks stdio, and a transcript-ready callback runs a local command — neither opens a network connection, so neither weakens this invariant.
- Anything portable to iOS lives in `CheerioKit`; Core Audio tap code stays in the app target.
- Realtime audio callbacks do no work — hand buffers off immediately (AsyncStream/Task).
- Two transcription engines (mic/system) for the Me/Them split — that's deliberate; don't merge streams. Diarization sits *on top* of them, per-channel, to tell people apart within one channel.
- Swift 6, strict concurrency complete. SwiftData for storage. MIT licensed.
- Formatting is enforced in CI: `swift format lint --strict` with the repo's `.swift-format`
  config. Run `swift format --in-place --recursive Cheerio CheerioKit/Sources CheerioKit/Tests`
  before pushing. Release builds come from `.github/workflows/release.yml` on `v*` tags —
  Developer ID-signed and notarized, then EdDSA-signed for Sparkle and published as an
  `appcast.xml` asset on the GitHub Release itself — the app's `SUFeedURL` is
  `https://github.com/ObviosCo/cheerio/releases/latest/download/appcast.xml`, which GitHub
  redirects to the newest release's copy. Nothing is committed to a branch (`main` is
  protected, and a release run shouldn't write to branches anyway); `site/appcast.xml` is now
  only the empty first-release seed. The six secrets it needs (five
  signing/notary plus `SPARKLE_ED_PRIVATE_KEY`) and the one-time key ceremony are documented
  in that workflow's header comment. **Never generate or commit the Sparkle private key** —
  that is the maintainer's to hold; the workflow refuses to release if the key it signs with
  doesn't match the `SUPublicEDKey` in the built app.
- Bundle prefix `app.cheerio` is a placeholder (`project.yml` TODO).
- New user-facing features decide whether the first-run walkthrough (`Cheerio/Views/Onboarding/`) needs to teach them — most won't, but a new permission or something as easy to miss as voice enrollment used to be, does.

## Reference

- AVAudioEngine **cannot** read a tap-backed aggregate device — raw IOProc only (see ARCHITECTURE.md).
- Working tap examples: github.com/makeusabrew/audiotee and the CATap gist by directmusic.
- WWDC26 `LanguageModel` protocol makes summarization models pluggable — v2, keep `SummarizationEngine`'s model injectable when touching it.
