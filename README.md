<img src="Cheerio/Resources/Assets.xcassets/AppIcon.appiconset/icon_128.png" width="96" alt="The Cheerio app icon: a copper ring on deep navy">

# Cheerio

[![CI](https://github.com/ObviosCo/cheerio/actions/workflows/ci.yml/badge.svg)](https://github.com/ObviosCo/cheerio/actions/workflows/ci.yml)

Open-source meeting transcripts for macOS, built to be acted on by the agents already running
on your machine. Like Granola, but single-user, no subscription, and free.

Cheerio records both sides of a meeting straight off your Mac's audio hardware, transcribes it
on-device, tells the participants apart by name, and merges the transcript with the rough notes
you typed during the call into structured enhanced notes. No bot joins your call, and no
third-party service sits between the recording and the output — the transcript and notes stay
in your library, ready to hand to whatever comes next.

> **Status: works, lightly tested.** The app builds and runs, the package tests pass, and
> speaker differentiation is verified for in-person meetings. On a video call played out
> loud, the mic still hears your speakers, so wear headphones — see
> [Current status](#current-status).

## Why

Granola-style meeting notes are excellent and require shipping your meetings to someone else's
servers on a subscription. As of macOS 26, Apple ships nearly everything needed to do it
locally: `SpeechAnalyzer`/`SpeechTranscriber` for transcription, the Foundation Models framework
for summarization, and Core Audio process taps for system audio. Cheerio is that, assembled —
plus one on-device model Apple doesn't provide, for telling speakers apart. That gets you a
Granola alternative with no service to depend on and nothing to subscribe to.

There's a second half to the story. People already use meeting transcripts as instructions for
AI agents: record yourself thinking out loud, or record a meeting, then paste the transcript
into Claude, Codex, or whatever agent is running, and let it act on what was said. That
workflow already exists — it's just manual, and a chat box is the wrong container for it. Prompt
boxes are size-limited and easy to overrun; a transcript is naturally long-form, which is
exactly what makes it a good prompt. Cheerio's job is to make that loop first-class: produce the
transcript locally, and let the agents already on your machine pick it up instead of you
copying and pasting it in. The agent-facing surfaces for this all shipped in v26.8.9: a
bundled MCP server (Settings → Agents), a transcript-ready callback (Settings → Callback),
and a directive-capture mode ("Give Direction…" in the menu bar, and in the main window's
recording controls — a recording can also be relabeled as one or the other afterward, from
its context menu or detail view).

## What it does

- **Capture without bots.** Two independent streams: your microphone through `AVAudioEngine`,
  and everyone else through a Core Audio process tap on system output. Works with Zoom, Meet,
  Teams, or anything else that makes sound. Because it captures audio rather than joining a
  call, nothing needs a meeting bot or a per-app integration, and no app-specific API has to
  support it first.
- **Transcribe on-device.** Each stream gets its own `SpeechTranscriber`, which is where the
  `Me` / `Them` split comes from. Live volatile results drive the in-meeting transcript, which
  follows new lines as they arrive and lets you scroll back without losing your place; final
  results are persisted with timestamps, shown sparsely — once per elapsed minute — so a long
  meeting stays a quiet transcript, not a column of numbers, and there's a place to jump into it
  from.
- **Tell people apart by name.** The channel split can't distinguish three people in one room,
  and `SpeechTranscriber` exposes no speaker information at all. So a Sortformer diarization
  pass runs over the recorded audio after the meeting. Enroll a voice once and it comes back
  named instead of "Speaker 2"; pick who was in a given meeting from a per-meeting roster; fix
  any label by hand, and your correction outranks the model. Once a model-matched name looks
  right, confirm it in one action instead of retyping it line by line — a re-identification pass
  leaves confirmed lines alone, the same as hand-named ones. Rename, confirm, and save a voice
  sample all live behind a per-speaker menu now, so the panel's foreground is talk time (a
  duration and a share of the meeting, per speaker) and a colour-coded timeline of who spoke
  when, not the correction controls themselves.
- **Rough notes are first-class.** A scratchpad sits next to the live transcript during the
  meeting. What you bothered to type is the strongest signal about what mattered. When a
  recording stops it isn't processed on the spot: the meeting waits in a short review window
  (two minutes of idle time by default — every edit restarts it; configurable in Settings ›
  General, and directives skip it) where notes you didn't get to type live still make it into
  the enhancement pass, and where you can set the meeting kind and decide whether the
  transcript-ready callback runs for this meeting, with an optional per-meeting prompt for it —
  and, when more than one callback trigger is configured, which one it goes to.
  Confirm to process immediately, or walk away and it processes itself. Notes stay editable
  from the meeting's detail view afterward too, for the follow-up thought that occurs to you
  once the call ends — but editing *there* doesn't re-run the enhancement pass below, which is
  stated outright rather than left to be discovered. Write in Markdown and it renders once the
  meeting's been processed — headings, lists, bold, links — with an Edit toggle to get back to
  plain text.
- **Enhance locally.** Afterwards the on-device Foundation Model merges your rough notes with
  the transcript into a summary, key points, decisions, and action items — attributed to
  whoever committed to them where the transcript supports it, and never promoted past the
  evidence: anything unattributed or disputed lands as a follow-up rather than something an
  agent might act on. Long meetings are handled map-reduce style to fit the model's ~4k-token context
  window.
- **Ready for the agents already on your machine.** A bundled MCP server, a transcript-ready
  callback, and a directive-capture mode — from the menu bar or the main window, and
  convertible after the fact if you forgot to say so going in — turn a finished meeting into
  something an agent can act on without you copying and pasting — see
  [Use with Claude Desktop, Claude Code, or any MCP client](#use-with-claude-desktop-claude-code-or-any-mcp-client)
  below. The callback isn't one command anymore: Settings → Callback manages several named
  triggers — a directive session to Claude Code against a repo, a client meeting to a triage
  prompt — with exactly one marked default. The default fires automatically; a different one
  can be picked in the post-meeting review window; and any trigger can be run against an
  already-processed meeting from its page, which is also how you re-process a meeting through
  a different agent.
- **Calendar-aware, optionally.** EventKit supplies the current event to title a recording and
  link it back. Denying calendar access costs you only the convenience.
- **Nothing to configure before your first recording.** First launch walks through the microphone,
  system-audio, and calendar permissions and enrolling your voice. Recordings title themselves — from the
  calendar event, or generated from the transcript when there wasn't one — and any title is
  yours to change by hand.
- **Library, search, and export.** Browse past meetings grouped by day — Today, Yesterday,
  then the weekday or the date — search across titles, notes, transcripts, and speaker names,
  rename or delete a meeting from the list or the meeting itself, and export any meeting as
  Markdown.
- **Nothing selected still shows something useful.** With no meeting open, the main window
  shows this week's upcoming calendar events (when access is granted), how many meetings and
  minutes you've recorded this week, how many follow-ups are still open, the two start actions,
  and a rotating tip. If no voice is enrolled yet, a prompt to fix that leads the way — it comes
  back every launch, in the empty state or as a banner above whatever meeting you do have open,
  until at least one voice is enrolled.
- **It comes to you when it matters.** A notification offers to record when a calendar meeting
  with other people starts (never twice for the same occurrence, never while already
  recording), and another one tells you when a finished meeting's notes are ready. Both
  switches live in the Notifications section of Settings → General.
- **Audio retention you control.** Raw audio is written to disk per channel so a transcription
  failure isn't fatal, then purged on your schedule — discard immediately, 24 hours, 3 days,
  7 days, 30 days, or keep forever. The default is 3 days.
- **Play a meeting back.** While the audio is still on disk, the meeting detail view offers a
  merged play/pause and scrubber over both channels — the affordance is simply absent, not
  disabled, once retention has purged it. The transcript is seekable too: hover any line and a
  play control with that line's time appears at its edge — one click starts playback from that
  moment (VoiceOver gets the same jump as a per-line action). Same rule as the scrubber: no
  retained audio, no control.

Full scope and non-goals: [`docs/SPEC.md`](docs/SPEC.md).

## Use with Claude Desktop, Claude Code, or any MCP client

Cheerio ships a small MCP server, `cheerio-mcp`, inside the app bundle — so the agents already
running on your Mac can look up what was said in a meeting instead of you copy-pasting a
transcript into them. It installs and updates with the app; there is nothing separate to
download.

Five tools, all read-only:

| Tool | What it does |
| --- | --- |
| `list_meetings` | Recent meetings, newest first. Filter by kind and date, paged. A recording is visible here from the moment it starts, marked `isInProgress`; finalized lines land within a couple of seconds of being spoken, though the line currently being spoken isn't there until transcription finalizes it. |
| `search_meetings` | Free text across titles, notes, speaker names, and every transcript line — the same match the app's own search uses. |
| `get_meeting` | One meeting in full: metadata, your rough notes, the enhanced notes, action items, transcript. |
| `get_transcript` | Just the speaker-labelled lines, each flagged with whether it was you talking. |
| `get_action_items` | Action items as structure, with `owner` and `disposition`. |

Nothing can write, delete, start a recording, or run a command.

**Adding it.** Cheerio's **Settings → Agents** shows the path to the helper *inside your actual
copy* of the app and a copy button for each client's config — it reads its own bundle location
rather than assuming one, so it's correct whether Cheerio is at `/Applications` (the default) or
`~/Applications` (where a standard, non-admin account's copy ends up if it was ever offered the
move — see [Download](#download)). The commands below are for the default
location; if yours differs, copy from Settings → Agents instead of these.

```sh
claude mcp add cheerio -- /Applications/Cheerio.app/Contents/Helpers/cheerio-mcp
```

For Claude Desktop, add this to `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "cheerio": {
      "command": "/Applications/Cheerio.app/Contents/Helpers/cheerio-mcp"
    }
  }
}
```

For Codex, in `~/.codex/config.toml`:

```toml
[mcp_servers.cheerio]
command = "/Applications/Cheerio.app/Contents/Helpers/cheerio-mcp"
```

Cheerio never edits those files for you — you paste the snippet in yourself.

**Letting an agent find it on its own.** An agent already running on your Mac shouldn't need
you in the loop to learn Cheerio exists. Every time Cheerio launches, it writes a small
discovery manifest at a fixed per-user path:

```
~/Library/Application Support/Cheerio/mcp-server.json
```

```json
{
  "command" : "/Applications/Cheerio.app/Contents/Helpers/cheerio-mcp",
  "description" : "Read-only access to Cheerio meeting transcripts, notes, and action items over MCP (stdio).",
  "name" : "cheerio",
  "transport" : {
    "type" : "stdio"
  },
  "updatedAt" : "2026-08-09T17:00:00Z",
  "version" : "1.4.0"
}
```

To connect, launch `command` — an absolute path, no arguments — and speak MCP over its
stdin/stdout, exactly what the snippets above configure by hand. `version` is Cheerio's own
version and may be absent on development builds. Two rules for readers:

- The manifest is rewritten on every launch, so it tracks wherever the app actually is —
  including after a move from `~/Applications` to `/Applications`.
- If nothing executable exists at `command`, the whole manifest is stale — Cheerio was moved
  or uninstalled and hasn't run since. Ignore it rather than trusting any other field.

This is one-directional advertising: the manifest is the only file Cheerio writes for
discovery, in a location of its own, and the rule above stands — Cheerio still never edits
another app's config. Whether an agent acts on the manifest is that agent's call.

**A note on `disposition`.** Action items say who committed. `actionable` means *you* did, and
an agent may carry it out; `followUp` means someone else committed, or nobody, so it's yours to
track and never theirs to do on your behalf. That comes from who was speaking, so it's a
permission rather than a priority — see below.

**How it reaches your meetings.** It's launched by the client and talks over that pipe: stdio
only, nothing listening, no networking path ever invoked, and no way for anything off your Mac
to reach it.
It opens Cheerio's store read-only and never writes to it. If you haven't run Cheerio yet, or
you've just updated it, the first tool call says so and tells you what to do rather than
failing cryptically. Details in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## No service required

Local models are the mechanism, not the point. There's no third-party service Cheerio depends
on and nothing to pay for month to month — you run it, and you control it.

- **Nothing needs the network while a meeting is recorded or processed.** That is the
  invariant, and it holds with the machine in airplane mode: capture, transcription, speaker
  attribution and note generation all run on-device, start to finish. The bundled MCP server
  is no exception — it talks over a pipe and never invokes a networking path. (The one
  code-level asterisk: FluidAudio, the diarization dependency, ships model-download code
  Cheerio never calls, because the model is bundled and its URL passed in.)
- **The app's only network access is checking for its own updates.** Sparkle fetches the
  update feed at `https://github.com/ObviosCo/cheerio/releases/latest/download/appcast.xml` on a
  daily schedule, and the zip if you accept an update — two requests, not one, both to GitHub
  Releases. Neither a
  scheduled nor a manual check will *start* while a recording is running (see
  [`Cheerio/Updates/AppUpdater.swift`](Cheerio/Updates/AppUpdater.swift)); an update already
  downloading when you hit record is left to finish rather than aborted mid-transfer. You can
  switch the checks off entirely in **Settings → Updates**; nothing else changes if you do.
- **No profile, no analytics — the requests carry nothing optional.** Sparkle's system profile — OS
  version, CPU, model, language appended to the feed request — is off, and the updater
  delegate refuses to add any feed parameters at all. What GitHub sees is what any HTTPS
  download shows a server: connection metadata and a User-Agent naming the app and Sparkle
  versions. No accounts, no telemetry, no analytics, no crash reporting.
- **Both models run on-device.** Speech and summarization use Apple's local models; diarization
  runs the bundled Sortformer model on the Neural Engine. The diarization model is downloaded
  at *build* time by a script, never at runtime.
- The only other network activity the app can cause is macOS itself fetching the speech model
  for your locale on first run.
- Nothing leaves the machine during a recording or while it's being processed — audio,
  transcript, and notes all stay in the app's local store until you export them yourself.

## Download

Prebuilt binaries are attached to [GitHub Releases](https://github.com/ObviosCo/cheerio/releases):
download `Cheerio-<version>.dmg`, open it, and drag Cheerio to `/Applications`. Install it there
rather than running it from `~/Downloads` — macOS runs an app from Downloads under app
translocation, a read-only mount from which Cheerio can't update itself. Builds are signed with
a Developer ID certificate and notarized by Apple, so Gatekeeper opens them without warnings or
right-click ceremony. Requires macOS 26 or later on Apple Silicon.

If you do launch it straight from the DMG or a translocated path, Cheerio notices and offers to
move itself to `/Applications` on the spot — or, if a copy is already installed there, points you
at that one instead of letting two copies collide. On a standard (non-admin) account that can't
write to `/Applications`, it falls back to `~/Applications` instead, which Cheerio treats as
equally stable. A dev build run from a build directory is unaffected; the check only fires for a
launch location Sparkle couldn't have updated anyway.

The `.zip` on the same release is the identical app; it's what the updater downloads, and
Sparkle prefers that format. Either one works if you install it to `/Applications`.

Later versions install themselves, so a second download is never needed. The app checks its own
update feed once a day, offers what it finds, and can be set to download and install without
asking — see **Settings → Updates**, and [No service required](#no-service-required) for exactly
what that costs in network terms.

To build from source instead:

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

- **Building your own fork or a distributable of your own?** Change one constant,
  leave another alone — they look similar and do opposite jobs. Change
  `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`, what the built app actually is (now
  the project's real identifier, `co.obvios.cheerio.mac`, not a placeholder; note it
  overrides `options.bundleIdPrefix`, so changing the prefix alone leaves you
  building under Obvios's), *and* `AudioStorage.appBundleIdentifier` in
  `CheerioKit/Sources/CheerioKit/Audio/AudioStorage.swift` — the one CheerioKit
  actually trusts as "the app's identifier," which doesn't follow `project.yml`
  automatically: the bundled MCP helper resolves its store against that constant
  rather than `Bundle.main` (see its doc comment for why). Leave it as
  `co.obvios.cheerio.mac` and your fork's helper looks for the *official* Cheerio's
  store, not yours. There's no shared-config system deriving one from the other —
  change both by hand.

  Do **not** change `AudioStorage.officialBundleIdentifier`, the other constant
  right next to it. It's a fixed `"co.obvios.cheerio.mac"` that exists only to gate
  the `app.cheerio.mac`-to-official migration and the DMG launch-location handoff's
  legacy-install match — both meaningless for a fork, which never shipped under the
  old identifier and has no legacy data of its own to find. It's deliberately not
  the same constant as `appBundleIdentifier`: if it were, a fork that correctly
  changed `appBundleIdentifier` per the paragraph above would end up matching its
  *own* new identifier against this check too, turning both of those behaviors back
  on by accident. Leaving it untouched is what keeps them off.

  An ordinary local Debug build needs none of this: Xcode signs it ad hoc under
  whatever identifier is there, and nothing reads any of these three constants until
  you actually record something.
- **Grant microphone access on first record.** Prompted once; if you deny it, macOS won't ask
  again and you'll need System Settings → Privacy & Security.
- **First launch downloads a speech model.** macOS fetches the `SpeechTranscriber` assets for
  your locale once, per locale, when a recording starts.
- **Enroll your voice in Settings.** Diarization returns names only for voices it has heard
  before. Samples need **at least 30 seconds** — shorter ones measurably cause the model to
  split one person across two speaker slots. "Mic check" arms a live level meter before you
  commit to a take, and saving a sample confirms it by name instead of quietly resetting the form.
- **On a video call, wear headphones.** With meeting audio playing out loud, the mic hears
  your speakers and remote voices land in both channels — see the echo issue below. There's
  no mode to set; every recording captures both channels the same way.

## Current status

Verified against this commit on macOS 27 / Xcode 26:

| Check | Result |
|---|---|
| `CheerioKit` tests | all pass (`cd CheerioKit && swift test`) |
| `Cheerio` app build | succeeds (2 warnings) |
| End-to-end capture | verified 2026-07-28 — both channels transcribe, notes generate, both CAFs write |
| Speaker differentiation, in person | verified 2026-07-31 — 9/9 segments labelled correctly across 1–2s alternating turns |
| Live video call | **not yet verified** |

Known issues, roughly in priority order:

- **The mic hears your speakers.** With meeting audio playing out loud, system audio lands in
  *both* channels and the transcript duplicates itself, which then skews the summary.
  Acoustic echo cancellation was tried and removed ([#167](https://github.com/ObviosCo/cheerio/issues/167)):
  with it enabled, a real video call recorded a completely silent mic channel
  ([#159](https://github.com/ObviosCo/cheerio/issues/159)) — losing half the meeting is worse
  than transcribing it twice. Wear headphones; deduplicating the bleed at the transcript
  level is tracked in [#168](https://github.com/ObviosCo/cheerio/issues/168).
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
- **Calendar is mostly read-only.** Recordings get their title and event ID from the current
  event, and a notification offers to record when a meeting starts — but "attach notes back to
  the event" isn't built.
- **No re-running transcription on retained audio.** Playback shipped in #14; the other half of
  that issue — re-transcribing a meeting whose first pass came out empty or wrong, using the
  same retained CAFs — hasn't.

**No Mac App Store.** App Sandbox has to stay off: a sandboxed process tap is created with
`noErr` at every step and then reads pure digital silence, with no permission prompt and no
error anywhere. Measured on identical code: `peak=0.0` sandboxed against `-1.8 dBFS`
unsandboxed. Hardened runtime stays on.

## Project layout

```
cheerio/
├── project.yml       # XcodeGen config → generates Cheerio.xcodeproj
├── Scripts/          # bootstrap.sh — fresh checkout → buildable; render-appicon.swift — app icon
│   └── screenshots/  # Seeds demo meetings and photographs the app; makes site/img
├── CheerioKit/       # SwiftPM package: portable core (macOS + future iOS)
│   └── Sources/CheerioKit/
│       ├── Models/           # SwiftData: Meeting, TranscriptSegment, EnrolledSpeaker
│       ├── Audio/            # CAF recording, retention, excerpts, storage
│       ├── Transcription/    # SpeechAnalyzer/SpeechTranscriber wrapper
│       ├── Diarization/      # Sortformer speaker attribution
│       ├── Summarization/    # Foundation Models wrapper, @Generable output
│       ├── Callback/         # Transcript-ready callback payload + settings
│       ├── MCP/              # Read-only store access, tools, JSON-RPC responder
│       ├── Onboarding/       # First-run state, portable
│       └── Calendar/         # EventKit wrapper
├── Cheerio/          # macOS app target
│   ├── Audio/        # Mic capture, Core Audio process tap, capture session
│   ├── Callback/     # Runs the transcript-ready callback command
│   ├── Design/       # Colour, type, spacing, motion + speaker/recording/status components
│   ├── Resources/    # Models/ — fetched, never committed
│   ├── Updates/      # Sparkle: the app's only network access
│   └── Views/        # SwiftUI, incl. Onboarding/ (first-run walkthrough)
├── CheerioScreenshotTests/  # UI tests that photograph the app; CI posts the result to the PR
└── CheerioMCP/       # cheerio-mcp — stdio MCP server, bundled inside the app
```

The rule: anything that could run on iOS lives in `CheerioKit`. System-audio capture is
macOS-only Core Audio, so it stays in the app target.

Design notes and the gotchas worth knowing before you touch the audio path:
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

What the app still needs from a designer — an icon, an identity and voice, a review of the
UI, and a website: [`docs/DESIGN-HANDOFF.md`](docs/DESIGN-HANDOFF.md).

## Roadmap

Near-term: deduplicating speaker bleed at the transcript level
([#168](https://github.com/ObviosCo/cheerio/issues/168) — the successor to acoustic echo
cancellation, which was removed after it silenced a real meeting's mic), an in-room vs.
remote toggle per participant, and re-running transcription on retained audio (the other
half of #14 — playback itself shipped).

The actionable-transcripts work ([epic #22](https://github.com/ObviosCo/cheerio/issues/22))
shipped in v26.8.9: owner-attributed action items, the transcript-ready callback, directive
mode, and the bundled MCP server are all in the app today.

Both capture channels stay on for every recording, directives included. An earlier
plan had recording modes skip the system tap for solo and in-person recording, on the
assumption that nothing worth capturing comes out of the machine — but input and output can
be different devices, and someone recording alone through AirPods still has system audio
worth keeping. Modes themselves are gone now too ([#167](https://github.com/ObviosCo/cheerio/issues/167)):
every recording captures the same way, with nothing to pick before you start.

Later: an iOS app for in-person meetings, pluggable summarization models via the `LanguageModel`
protocol, semantic search, Obsidian folder auto-export, and a first-party CLI once the callback
and MCP server prove out the shape agents actually want.

## Contributing

Issues and pull requests are welcome. Two constraints are not up for negotiation: **nothing
may need the network while recording or processing a meeting** (the app's only networking is
the Sparkle update check, against Cheerio's own distribution endpoints, and it steps aside
while a recording is running — a one-time setup download would also be acceptable, a
dependency during capture never is), and no analytics or accounts. Beyond that, keep portable
logic in `CheerioKit`, do no work on realtime audio callbacks, and leave strict concurrency on.

CI runs `swift format lint --strict` (config in [`.swift-format`](.swift-format)), the package
tests, and an app build on every PR. A PR that touches the UI also gets automated
accessibility audits — every covered screen, light and dark, contrast first — and screenshot
previews; an audit finding is a red check, same as failing lint. Format locally before
pushing:

```sh
swift format --in-place --recursive Cheerio CheerioMCP CheerioScreenshotTests CheerioAccessibilityTests CheerioKit/Sources CheerioKit/Tests
```

## License

Cheerio itself is MIT — see [LICENSE](LICENSE). So is **Sparkle**, the updater; its notice
still has to travel with a build, and does.

Two things it depends on are neither MIT nor permissive in the same way:

- **FluidAudio** (Apache-2.0), the Swift wrapper around Sortformer.
- **Sortformer v2.1**, the diarization model — © NVIDIA, licensed
  [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/), with the Core ML conversion by
  [FluidInference](https://huggingface.co/FluidInference/diar-streaming-sortformer-coreml)
  under the same license. Redistributing it — including inside a built app — is fine as long
  as the attribution in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) travels with it,
  which the build does for you by bundling that file into the app. The model is kept out of
  the repo because it's ~93 MB, not because the license requires it.
