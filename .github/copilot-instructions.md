# Cheerio review instructions

Cheerio is a macOS-first app that turns meetings into AI-actionable transcripts, on-device
(SpeechAnalyzer/SpeechTranscriber for transcription, Foundation Models for summaries, Core
Audio process taps for system audio). `CLAUDE.md` is the upstream source of truth for these
rules — if this file and
`CLAUDE.md` ever disagree, `CLAUDE.md` wins and this file is stale.

When reviewing a PR, check for the following. Flag violations; don't just note them as style
preferences.

## Hard invariants

- **No network while recording or processing a meeting.** Nothing reachable from a capture
  or processing path may add `URLSession`, sockets, or `import Network`. A one-time
  install/setup-time download (e.g. fetching a model) is fine; a network dependency during
  capture or processing is never fine.
- **App Sandbox must stay off.** A sandboxed process tap returns silence with no error and no
  TCC prompt — if a diff re-enables the App Sandbox entitlement to "fix" a capture bug,
  that's the regression, not a fix.
- **Both capture channels run in every recording.** Mic and system audio both start
  unconditionally — nothing may gate whether `SystemAudioTap` starts. The mic path is plain
  capture: voice processing / acoustic echo cancellation was removed after it silenced a
  real meeting's mic channel (#167); flag any diff that reintroduces
  `setVoiceProcessingEnabled` or a recording-mode setting.
- **Realtime audio callbacks do no work.** AVAudioEngine taps and the tap IOProc must hand
  buffers off immediately (e.g. via `AsyncStream`/`Task`) — flag any parsing, allocation, or
  logging added inside a callback.
- **Anything portable to iOS lives in `CheerioKit`.** Models, transcription, summarization,
  diarization, and calendar logic belong in the package. The app target (`Cheerio/`) keeps
  what is genuinely macOS-specific — SwiftUI views, mic capture, the Core Audio system tap,
  capture orchestration. Flag portable logic added to `Cheerio/`, not app concerns living
  where they should.
- **Swift 6 strict concurrency stays on.** Flag new `@unchecked Sendable`,
  `nonisolated(unsafe)`, or relaxed concurrency checking that silences a real data race
  instead of fixing it.
- **The mic/system split is deliberate.** Two transcription engines exist for the Me/Them
  split — flag any change that merges the streams. Diarization (speaker attribution) sits on
  top of each channel; it doesn't replace the split.

## UI-affecting PRs

If the diff changes what the user sees (views, copy, icons, first-run flow):

- Do NOT ask for `site/img` screenshot regeneration on a PR. The convention: site imagery
  documents the *released* build and is regenerated once per release by the release
  checklist, never per-PR; the CI capture previews posted on the PR are the review-time
  evidence for visual changes. Flag site *copy* (`site/*.html`) that a PR makes factually
  wrong, but the images are release-day work by design.
- Ask whether the first-run walkthrough (#30) needs to teach the change.

(`.github/instructions/ui-changes.instructions.md` also applies this check specifically to
`Cheerio/Views/**` diffs.)

## Every behavior-changing PR

Not just UI: new MCP tools, callback semantics, capture behavior, settings — anything a user
or their agent can observe.

- Ask whether this PR changes behavior the README describes or should describe. Flag PRs that
  add or remove user-facing capability without touching `README.md` — a stale README claim is
  the same class of problem as a missing screenshot update, just easier to miss.

## Mechanics

- **`.xcodeproj` is generated, not source.** `project.yml` is the source of truth for the
  Xcode project; new files need `xcodegen generate` (wrapped by
  `./Scripts/bootstrap.sh`) to be picked up. Never treat a hand-edited `.xcodeproj` diff as
  authoritative, and don't ask for one to be committed.
- **`.swift-format` at the repo root is the formatting authority.** CI runs
  `swift format lint --recursive --strict Cheerio CheerioMCP CheerioScreenshotTests CheerioAccessibilityTests CheerioKit/Sources CheerioKit/Tests` — don't
  request stylistic changes that would conflict with it.
- **Tasks live in GitHub issues, never in `CLAUDE.md`.** Flag any PR that adds a to-do/backlog
  section to `CLAUDE.md` instead of opening or linking an issue.
