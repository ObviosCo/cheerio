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

The model itself (~93 MB) is not committed. `Scripts/fetch-models.sh` downloads it against pinned SHA-256 hashes and also runs as a pre-build phase. The model is **CC BY 4.0** (© NVIDIA; Core ML conversion by FluidInference), not MIT — redistribution is allowed with attribution, which ships in `THIRD-PARTY-NOTICES.md` inside the app bundle. Keeping it out of the tree is a size decision, not a license requirement.

`Scripts/bootstrap.sh` is what a fresh checkout should run — it verifies the toolchain, fetches the model, and generates the project in that order. The order is load-bearing: `project.yml` references the `.mlmodelc` as a folder reference, so `xcodegen generate` refuses to write a project until the model is on disk, and the pre-build phase can't cover that gap because there's no project yet to hang a phase on.

It is fetched at *build* time, never at runtime. The app does have networking code now — Sparkle, for updates — but it is deliberately confined to that, and nothing in the capture or processing path is allowed to reach for it. The hard requirement: nothing may need the network *while recording or processing a meeting*. A one-time download at install or first launch would be acceptable if there were ever a reason for one; bundling the model just makes the question moot.

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

- What the model produces are `@Generable` structs (`NotesDraft`, `ActionItemDraft`) — type-checked, no JSON parsing. What the app stores is `EnhancedNotes`, holding vetted `ActionItem`s. The "draft" half of that vocabulary means *unverified attribution*
- The on-device model's context window is small (~4k tokens). Long meetings use map-reduce: transcript → chunks → one structured extraction per chunk → merge. The lists merge deterministically and only the prose summary takes a second model pass. Chunks are extracted rather than condensed to prose first, because condensing discards the speaker labels before anything has attributed a commitment
- Check `SystemLanguageModel.default.availability` and degrade gracefully (transcript-only mode)
- v2: swap models via the WWDC26 `LanguageModel` protocol — the engine already takes the model as an injected dependency

### Speaker identity as a trust signal

An action item carries an `owner` and a `disposition`: `actionable` means the owner committed to it themselves and an agent may do it for them; `followUp` means someone else committed, so track it and never do it. Whose voice said it is what decides that.

- The prompt is *told* which speaker labels are the owner's (the enrolled `isMe` names, threaded in from the caller — the engine never touches a `ModelContext`), so attribution starts from the transcript rather than from the model's guess at who "I" is.
- The prompt is not trusted with it. `ActionItem.resolved(from:ownerNames:)` is the only way an `ActionItem` is constructed, and it **demotes anything not attributed to the owner** — a named guest, a "Speaker 2", a group ("we", "the team"), or nobody at all. It only ever demotes: an item the model called a follow-up stays one even for the owner, because the model may have seen a dependency the owner check can't.
- Merging across chunks is conservative the same way: two chunks disagreeing about who committed resolves to `followUp`.
- The failure it is designed around: an agent doing someone else's committed work is far worse than the owner re-reading a follow-up they could have delegated.

`Meeting.actionItems` persists the vetted items next to the Markdown, and `MeetingExport` carries them, so downstream consumers route on structure rather than parsing prose.

## Storage

SwiftData, single local store. `Meeting` (title, times, event ID, rough notes, enhanced notes, per-meeting participant roster) 1-many `TranscriptSegment` (speaker channel, text, time range, resolved speaker label, and whether that label was set by hand). `EnrolledSpeaker` holds a known voice: name, reference-audio path, duration, and an `isMe` flag.

Audio lives in Application Support, referenced by path, one CAF per channel per meeting. `AudioRetention` purges it on a schedule — immediately, 24 hours, 7 days, 30 days, or never — defaulting to 7 days. Transcripts and notes are never touched by retention; only the raw audio.

Note which location the app reads depends on the sandbox flag: a sandboxed build resolves Application Support to `~/Library/Containers/app.cheerio.mac/Data/`, an unsandboxed one to `~/Library`. Since the sandbox is off (below), it's the latter.

> Gotcha: toggling that flag migrates nothing. It changes where subsequent reads and writes land, leaving whatever was already written stranded in the other location — so a store full of meetings can present as total data loss when it is only being read from the wrong place. Nothing in the app moves a store across that boundary: a store migration existed once and was deliberately removed as unsafe (it keyed off SwiftData's default `default.store` filename in a *shared* directory, so it could not establish provenance and might have moved another app's database). `StorageMigration` addresses a different problem — relocating meeting audio out of the shared `~/Library/Application Support` into Cheerio's own container — and touches only directories recorded on our own `Meeting` objects.

## Concurrency

Swift 6 strict concurrency. Audio IOProcs/taps hand buffers off through `AsyncStream` immediately — no work on the realtime thread. Engines are actors; UI observes `@Observable` view models on `@MainActor`.

## Permissions & entitlements

**App Sandbox off — do not turn it back on.** A sandboxed process tap is created with `noErr` at every step and then reads pure digital silence: no TCC prompt, no error anywhere, and it presents exactly like a transcription bug. Measured on identical code, `peak=0.0` sandboxed against `-1.8 dBFS` unsandboxed. `SystemAudioTap`'s `SilenceWatch` logs the verdict at `.notice`/`.error` on stop, which is the quickest way to recognise it. This rules out Mac App Store distribution. Hardened runtime stays on.

`com.apple.security.device.audio-input`, `com.apple.security.personal-information.calendars`. Usage strings: mic, audio capture, calendar. No network entitlement.

One consequence of the sandbox being off: the missing network entitlement no longer *enforces* anything — entitlements only constrain a sandboxed process. So local-only rests on review, not on the system.

What that means concretely, now that Sparkle is in the app:

- **The invariant is unchanged**: recording and processing a meeting must never need the network. Every model is on the machine, and the diarization model ships in the bundle, so nothing in that path opens a connection. A one-time setup download would be compatible with the invariant; a connection during capture never is.
- **There is exactly one thing in the app that talks to the network**, and it is the updater: `Cheerio/Updates/AppUpdater.swift`. It fetches the appcast from `https://github.com/ObviosCo/cheerio/releases/latest/download/appcast.xml` — a release asset, not the website — and, if the user accepts, the zip from that same release. Nothing else in the app should contain `URLSession`, sockets or `import Network` — that is the line to hold in review, and it is narrower and more checkable than "no networking code".
- **Updates keep out of the way of capture.** `UpdatePolicy` implements `updater(_:mayPerform:)` and refuses *every* check start — scheduled or user-initiated — unless `CaptureSession.state == .idle`; a manual check gets the refusal shown by Sparkle's UI. For scheduled checks Sparkle treats the refusal as a deferral and reschedules, but it also stamps the attempt as the last check, so a vetoed check waits out the next interval rather than retrying when the meeting ends; a vetoed manual check is simply retried by the user. What the gate deliberately does not do is abort a check or download admitted while idle if a recording starts mid-cycle — that stays a documented edge, not machinery.
- **No analytics, still.** Sparkle's system profile would append OS version, CPU, model and language to the feed request. `SUEnableSystemProfiling` is false, `sendsSystemProfile` is set false in code, and the delegate returns no feed parameters and no allowed profile keys. Three refusals for one switch, because the invariant is worth more than the tidiness.
