# Cheerio — Codex handoff

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

Builds and runs; the package test suite passes (`cd CheerioKit && swift test` — the count moves with every PR, so this file doesn't track it). Acoustic echo cancellation now runs behind `RecordingMode.videoCall` (#12), but it's **not yet verified against a live call** with real speaker playback — that measurement, not the code, is what still gates closing #5. Run `Scripts/aec-ab-measure.sh` against a real before/after recording to make the call.

Two build warnings remain, both `Binding<Optional<Wrapped>>` captured in a `@Sendable` closure in `Views/Binding+Presented.swift`.

Speaker differentiation *is* verified for in-person meetings: on 2026-07-31, with Jackson and Carter both enrolled, a 51s two-person recording labelled 9/9 segments correctly — including 1–2s alternating turns — against narrated ground truth. `them.caf` measured −90 dBFS (silent) for that meeting, so all of it came from Sortformer, none from the channel split.

- `CheerioKit/` — SwiftPM package: SwiftData models, `TranscriptionEngine` (actor per audio channel), `SummarizationEngine` (map-reduce over ~4k-token on-device context), `CalendarService`, `MeetingAudioRecorder` + retention policy, `SpeakerAttributionService` (diarization). Swift Testing target covers buffer copying, CAF writing, retention math, search, and overlap-based speaker labelling.
- Two third-party dependencies, both pinned exactly (the convention, not an accident):
  - **FluidAudio** (Apache-2.0), in `CheerioKit`. Wraps Sortformer on Core ML/ANE for speaker diarization, because `SpeechTranscriber` has no speaker surface at all. Sortformer resolves **at most 4 speakers**.
  - **Sparkle 2** (MIT), on the app target only — declared in `project.yml`, not `Package.swift`, so both SwiftPM cache keys in CI hash `project.yml` too. Automatic updates; see `Cheerio/Updates/AppUpdater.swift` and the network bullet below.
- `Cheerio/` — macOS app target: `MicrophoneCapture` (AVAudioEngine), `SystemAudioTap` (CATap → aggregate device → IOProc), `CaptureSession` (@Observable orchestrator), `AppUpdater` (Sparkle), SwiftUI views incl. Settings.
- `CheerioMCP/` — `cheerio-mcp`, a stdio MCP server copied into `Cheerio.app/Contents/Helpers/`. Deliberately thin: `main.swift` plus file-descriptor work, with every answer coming from `CheerioKit/MCP/`. The protocol is hand-written rather than the official Swift SDK, which would have linked `import Network` and `URLSession` into the bundle — see ARCHITECTURE.md before reconsidering that. **It opens the store read-only and must never write**; `Meeting.stableID` backfills `uuid` on access, so the read path goes through `readOnlyExport` instead.
- `CheerioScreenshotTests/` — a UI-testing bundle (scheme `CheerioScreenshots`) that photographs the app's screens against a seeded demo store. Run by `.github/workflows/screenshots.yml` on PRs touching `Cheerio/Views/**`, `Cheerio/*.swift` or `site/**`, which captures and uploads an artifact and publishes nothing; `.github/workflows/screenshots-publish.yml` (`workflow_run`) is what puts the captures on the orphan `screenshots` branch and into one sticky PR comment. **That split is a trust boundary — see the permissions constraint below before merging them back.** Deliberately outside the `Cheerio` scheme, so an ordinary test run never starts driving a GUI. `Scripts/screenshots/README.md` has both capture paths and what each is for. Site imagery (`site/img`) is regenerated once per release by the release checklist, never per-PR — per-PR visual evidence is the CI capture preview.
- No `.xcodeproj` committed — generated via XcodeGen from `project.yml`. **Re-run `xcodegen generate` after adding files**, or the build won't see them.

## Build

```sh
brew install xcodegen     # if needed
./Scripts/bootstrap.sh    # checks tooling, fetches the model, generates the project
open Cheerio.xcodeproj    # scheme: Cheerio
```

Requires macOS 26+, Xcode 26+. Package tests: `cd CheerioKit && swift test`.

The full verification loop any change must pass before pushing — this list is the
canonical one; the agent definitions in `.Codex/agents/` carry mirrors of it for
self-containment, so change both together:

```sh
./Scripts/bootstrap.sh    # only needed if Cheerio/Resources/Models or the .xcodeproj is missing
swift format --in-place --recursive Cheerio CheerioMCP CheerioScreenshotTests CheerioKit/Sources CheerioKit/Tests   # drop CheerioMCP if absent
swift format lint --recursive --strict Cheerio CheerioMCP CheerioScreenshotTests CheerioKit/Sources CheerioKit/Tests   # drop CheerioMCP if absent
swift test --package-path CheerioKit
xcodegen generate         # mandatory after adding/removing files
xcodebuild build -project Cheerio.xcodeproj -scheme Cheerio -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -quiet
```

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
speakers, so calls transcribe twice — the fix landed behind `RecordingMode.videoCall`,
but closing the issue needs a live A/B against real speaker playback, which hasn't
happened yet) and **#9** (the live transcript can only show Me/Them, which looks
like a bug and isn't).

## Agents

`.Codex/agents/` has five checked-in subagent definitions for this repo's recurring work:
`orchestrator` (runs a whole body of work end to end — directive transcript → issues →
delegated PRs → reviewed merges → release — delegating to the other four and reviewing
everything before it ships), `swift-implementer` (scoped feature/fix on a branch),
`review-responder` (Copilot review triage), `release-editor`
(`.github/workflows/release.yml` and `Scripts/`), and `issue-groomer` (closing issues
addressed by merged PRs). The Build section's verification
loop is the single canonical copy; the agent definitions restate it for self-containment, so
update them alongside Build whenever the commands change.

## Conventions & constraints

- **App Sandbox must stay off.** A sandboxed build creates the tap with `noErr` at every step and then reads pure digital silence, with no TCC prompt — it looks like a transcription bug but it's a capture-permission failure. Measured: `peak=0.0` sandboxed vs `-1.8 dBFS` unsandboxed, same code. This rules out Mac App Store distribution. `SystemAudioTap`'s `SilenceWatch` logs the verdict at `.notice`/`.error` on stop (`.info` never reaches `log show`).
- **Both capture channels run in every recording mode.** Input and output can be different devices, so a solo recording through AirPods still has system audio worth keeping. `RecordingMode` (#12) drives echo cancellation, never whether the tap starts.
- **What "no third-party service" means mechanically:** nothing may need the network while recording or processing a meeting. That invariant is unchanged and still the thing to protect in review — but the app is no longer free of networking code. Sparkle fetches the appcast and, if accepted, an update zip — both assets of Cheerio's own GitHub Releases — and `UpdatePolicy` in `Cheerio/Updates/AppUpdater.swift` refuses *every* check start — scheduled or user-initiated — while `CaptureSession.state != .idle` (a download admitted while idle isn't aborted mid-cycle; documented edge, not machinery). With the sandbox off nothing enforces any of this, so review is the enforcement: capture and processing must stay free of `URLSession`, sockets, and `import Network`, and Sparkle must stay the only thing that talks to the network at all. A one-time download at install/setup (e.g. fetching a model) would also be acceptable; a network dependency during capture never is. Sparkle's system profile stays off — no analytics, no accounts. This isn't air-gapping for its own sake — it's the mechanical form of "no subscription, no third party." It doesn't rule out local surfaces for other processes on the same machine: a future MCP server speaks stdio, and a transcript-ready callback runs a local command — neither opens a network connection, so neither weakens this invariant.
- **A `pull_request` workflow never gets a write token.** `screenshots.yml` runs unreviewed code from the PR — `bootstrap.sh`, the seeder, the test bundle, everything under `Scripts/screenshots/`, and the workflow file itself — so it has `contents: read` and nothing else, and hands its captures on as an artifact. `screenshots-publish.yml` holds the write token, and it can because `workflow_run` runs the *base branch's* scripts in the base repo's context. `ci/verify-handoff.sh` is the seam: the artifact is validated as hostile input, and the PR number and head SHA come from the `workflow_run` payload rather than from anything the artifact claims. Don't move a publishing step back across that line, and don't add permissions to the capture side.
- Anything portable to iOS lives in `CheerioKit`; Core Audio tap code stays in the app target.
- Realtime audio callbacks do no work — hand buffers off immediately (AsyncStream/Task).
- Two transcription engines (mic/system) for the Me/Them split — that's deliberate; don't merge streams. Diarization sits *on top* of them, per-channel, to tell people apart within one channel.
- Swift 6, strict concurrency complete. SwiftData for storage. MIT licensed.
- Formatting is enforced in CI: `swift format lint --strict` with the repo's `.swift-format`
  config. Run `swift format --in-place --recursive Cheerio CheerioMCP CheerioScreenshotTests CheerioKit/Sources CheerioKit/Tests`
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
- **Every release ships the app twice**: a DMG (what people download) and a zip (what Sparkle
  downloads, and the appcast's enclosure — don't switch it to the DMG). The DMG exists because
  Safari auto-extracts a zip, people run `Cheerio.app` from `~/Downloads`, and macOS translocates
  it to a read-only mount where Sparkle can never update it. Built by `Scripts/make-dmg.sh` with
  `dmgbuild` (pinned with hashes in `Scripts/dmg-requirements.txt`), laid out per
  `Scripts/dmg-settings.py`, over art from `Scripts/render-dmg-background.swift` — generated, not
  committed. `Scripts/verify-dmg.py` mounts the result and fails the build if the layout doesn't
  match the settings, because writing a `.DS_Store` fails silently. The DMG is signed, notarized
  and stapled **separately** from the app: neither container is nested in the other, so one
  submission can't cover both.
- The app icon PNGs in `Cheerio/Resources/Assets.xcassets` are generated by `Scripts/render-appicon.swift` — edit the script and re-run it, never the PNGs. The art is full-bleed square on purpose; macOS 26 applies the squircle mask itself.
- Bundle identifier is `co.obvios.cheerio.mac` — resolved from the `app.cheerio.mac`
  placeholder (see the tracking epic, #22). Existing installs carry that data
  forward automatically: `BundleIdentifierMigration` moves the whole Application
  Support container on first launch under the new identifier, and
  `UserDefaultsMigration` copies every preference (onboarding, retention, recording
  mode, the notification ledger, Sparkle's own settings) into the new domain. Both
  are one-time, idempotent, and never overwrite something already at the
  destination — see `docs/ARCHITECTURE.md`'s Storage section for the full mechanics,
  including what happens if the directory move itself fails.
- New user-facing features decide whether the first-run walkthrough (`Cheerio/Views/Onboarding/`) needs to teach them — most won't, but a new permission or something as easy to miss as voice enrollment used to be, does.
- **The README describes the shipped app.** A PR that changes user-facing behavior updates the README's claims in the same PR — features added, limitations removed, status changed. Stale README claims are review-blocking, same as failing lint.

## Reference

- AVAudioEngine **cannot** read a tap-backed aggregate device — raw IOProc only (see ARCHITECTURE.md).
- Working tap examples: github.com/makeusabrew/audiotee and the CATap gist by directmusic.
- WWDC26 `LanguageModel` protocol makes summarization models pluggable — v2, keep `SummarizationEngine`'s model injectable when touching it.
