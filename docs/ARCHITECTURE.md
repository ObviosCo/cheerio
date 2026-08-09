# Cheerio — Architecture

## Layout

```
cheerio/
├── project.yml          # XcodeGen config → generates Cheerio.xcodeproj
├── Scripts/             # bootstrap.sh (fresh checkout → buildable), fetch-models.sh, render-appicon.swift
├── CheerioKit/          # SwiftPM package: platform-portable core (macOS + future iOS)
│   └── Sources/CheerioKit/
│       ├── Models/          # SwiftData models: Meeting, TranscriptSegment, EnrolledSpeaker
│       ├── Audio/           # CAF recording, retention policy, excerpts, storage paths
│       ├── Transcription/   # SpeechAnalyzer/SpeechTranscriber wrapper
│       ├── Diarization/     # SpeakerAttributionService — Sortformer via FluidAudio
│       ├── Summarization/   # Foundation Models wrapper + @Generable output types
│       ├── Callback/        # Transcript-ready callback payload + settings
│       ├── MCP/             # Read-only store access, tool handlers, JSON-RPC responder
│       └── Calendar/        # EventKit wrapper
├── Cheerio/             # macOS app target
│   ├── Audio/           # Mic capture, Core Audio process tap, capture session, labelling
│   ├── Resources/       # Models/ — fetched at build time, never committed
│   └── Views/           # SwiftUI
└── CheerioMCP/          # cheerio-mcp: stdio MCP server, bundled in Contents/Helpers/
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

**Mic:** `AVAudioEngine` input tap, optionally with voice processing (`setVoiceProcessingEnabled(true)`) turned on first for acoustic echo cancellation — `RecordingMode.videoCall` opts in, `RecordingMode.inPerson` leaves it off, since AEC targets a far-end signal that doesn't exist in a room with no speakers playing anything back. It has to be flipped before the engine starts, and it can change what `inputNode.outputFormat(forBus:)` reports, so the tap's format is read after that call rather than assumed — everything downstream already derives its format from the buffer it's handed, not a fixed expectation. Portable to iOS as-is.

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

## The bundled MCP server

`cheerio-mcp` is a command-line tool built from `CheerioMCP/` and copied into `Cheerio.app/Contents/Helpers/`, so it installs and versions with the app. It speaks the Model Context Protocol over stdio and exposes five read-only tools: `list_meetings`, `get_meeting`, `get_transcript`, `search_meetings`, `get_action_items`. It reports the *app's* version, read out of `Contents/Info.plist` two directories up, rather than carrying a number of its own.

The callback (#26) pushes; this pulls. An agent mid-way through unrelated work can ask what was decided on Tuesday without Cheerio having initiated anything.

Where the code lives is the design: everything that answers a question is in `CheerioKit/MCP/` — `MeetingStore` (opening), `MeetingQueryService` (queries), `MeetingMCPTool` (the tool surface), `CheerioMCPResponder` (one JSON-RPC message in, one out). `CheerioMCP/` holds only `main.swift` and the file-descriptor work. That split is what makes the server testable without a transport, which matters more here than usual because the protocol is hand-written.

`Contents/Helpers` rather than `Contents/MacOS`: Xcode has no named copy destination for it, so `project.yml` uses the "Wrapper" destination with a subpath. The point is that `Contents/MacOS` keeps holding exactly one executable, so nothing — Launch Services included — can mistake the helper for the app's main binary. The nested executable is code-signed in its own right; an unsigned one fails notarization for the whole bundle.

### Why the protocol is hand-written

The official [`modelcontextprotocol/swift-sdk`](https://github.com/modelcontextprotocol/swift-sdk) was the default choice and was rejected on measurements, not taste:

- Its `MCP` library target contains `import Network` (`NetworkTransport`) and seven `URLSession` call sites (`HTTPClientTransport` and the OAuth stack). Those compile and link on macOS whether or not you construct them.
- Depending on the `MCP` product alone resolves `swift-nio`, `swift-atomics` and `swift-collections` — six external packages, ~33 MB of source, against a repo that has exactly one pinned dependency today. Its own manifest has a `branch: "main"` dependency, which can't be pinned exactly.
- The `LICENSE` is a mid-transition mix of Apache-2.0 and MIT with no per-file markers, which complicates `THIRD-PARTY-NOTICES.md` rather than settling it.
- It is pre-1.0, and the open issue on `StdioTransport` interleaving concurrent sends under `EAGAIN` backpressure is a framing bug in precisely the transport this would use.

What a stdio, tools-only, read-only server needs is `initialize`, `tools/list`, `tools/call`, `ping`, newline-delimited framing and a JSON-RPC error envelope — a few hundred lines. **The trade accepted: protocol drift is now Cheerio's problem.** The mitigations are that the supported revisions are listed explicitly in `CheerioMCPResponder.supportedProtocolVersions`, that an unrecognized version negotiates down rather than failing, and that every response shape a client depends on is pinned by `CheerioMCPResponderTests`.

Being precise about the networking claim, since it is the load-bearing argument above: **the helper adds no networking code**, verified by grep and by `otool -L` showing no `Network.framework`. It does inherit a CFNetwork link, because it links `CheerioKit` and therefore FluidAudio, which ships `URLSession`-based model downloaders that Cheerio never calls (the model is bundled and its URL passed in). The app has that same link today. The distinction that matters is between a dependency whose networking is in a code path we provably don't use, and one whose networking is in the transport layer of the component we would be using.

Cost worth knowing: the helper links all of `CheerioKit`, so it pulls in Speech, FoundationModels, EventKit and FluidAudio for a binary that only reads SwiftData — about 13 MB in a Debug build. Splitting the package would fix it and isn't worth the churn yet.

### Reading the store from a second process

The helper opens the app's store with `ModelConfiguration(url:allowsSave: false)` and never calls `save()`. Concurrent access is safe because SwiftData sits on Core Data's SQLite store in WAL mode: a reader takes a snapshot and neither blocks nor is blocked by the single writer. Verified against a copy of a real 14-meeting, 1095-segment store, read correctly from a second process while the file was untouched (identical checksum after a full tool sweep).

Three things this turned up, all of which shape the design:

- **A read-only open cannot migrate.** Point the helper at a store written by an older schema and `ModelContainer` fails with `NSCocoaErrorDomain 134110`, "Cannot migrate store in-place: attempt to write a readonly database" — adding columns is a write. `MeetingStore.Failure.unreadable` says so in words, and tells the user to launch the matching Cheerio once. It never falls back to opening writably.
- **A missing store must not be created.** `ModelConfiguration` pointed at a nonexistent file makes one, so the helper checks for the file first: answering "you have no meetings" out of an empty database it had just laid down would be worse than any error. `MeetingStore.Failure.noStore` explains it, and the store is opened lazily on the first tool call rather than at launch, so a client started before Cheerio ever ran recovers by itself once it has.
- **`Meeting.stableID` writes.** It backfills `uuid` on first access, which is right for the app and disqualifying for a read-only reader — so `MeetingExport`'s ordinary initializer is unusable here. `Meeting.readOnlyExport(ownerNames:)` reads `uuid` directly and returns nil when it is absent. Legacy rows are then *listed* with a null `uuid` and an `unavailable` explanation rather than hidden, and can't be fetched by id. The helper does not derive a substitute identifier: the one the app will mint differs from anything guessed here, so a cached guess would be a key to nothing and MCP and the callback would name the same meeting two different things. Instead `StorageMigration.backfillMeetingIDs` runs at app launch, in the process that *is* allowed to write. That is not theoretical tidying — every one of the 14 meetings in the real store read as `uuid == nil` after migration, so without it the helper could not have addressed a single one.

Contexts are created fresh per call, not held: the app keeps recording and relabelling underneath, and a long-lived context would answer the second question out of the row cache it filled answering the first.

**The meeting exists before it's over.** `CaptureSession` builds the `Meeting` object at the top of `startCapturing`, but doesn't insert it into the `ModelContext` — let alone save — until both capture channels have actually started, immediately before `state` flips to `.recording`. Not at `stop()`, and not any earlier either: everything between construction and that point (either transcription engine's `start()`, either capture source's `start()`) can still throw, unwinding through the existing failed-start rollback. The insert itself is what's deferred, not just the save that follows it — the `context` this runs against is always the environment's `ModelContext` (every call site reaches `CaptureSession.start(context:)` through `@Environment(\.modelContext)` or `ModelContainer.mainContext`), which this app never opts out of SwiftData's default `autosaveEnabled = true` for, unlike `MeetingQueryService.makeContext()` above, which sets `autosaveEnabled = false` explicitly because that context must never write on its own. Inserting early and only deferring the explicit `save()` would still leave the meeting sitting in this autosaving context's pending changes across every `await` in setup, any of which could let the run loop service something that trips autosave before this function's own save runs — persisting a meeting for a recording that then fails to start, permanently if the rollback's own best-effort save then failed too. Deferring the insert itself closes that gap: nothing is pending for autosave to act on until the insert runs, and nothing suspends between the insert and the explicit `save()` two lines later. Read `stableID` at that same point, so the row that lands on disk already carries the same identifier `fireTranscriptReadyCallback` will hand out later. Finalized `TranscriptSegment`s are checkpointed on a periodic save afterward (`CaptureSession.checkpointInterval`, off the realtime audio path) rather than folded into that one save at the end, so a reader sees each finalized line within that interval of it finalizing, instead of only once the meeting ends. That bound covers finalized segments only: the line currently being spoken (`CaptureSession.volatileLine`) is never inserted into the context at all, so no checkpoint cadence makes it visible — a reader sees it only once transcription finalizes it, same as it would with no checkpointing at all. A crash mid-recording leaves that partial meeting behind with `endedAt` still nil; `StorageMigration.closeAbandonedRecordings` backfills it from the last transcribed timestamp the next time the app launches, so a call nobody is still recording doesn't read as in progress forever.

`CHEERIO_STORE_PATH` overrides which store file is read. It exists so a smoke test or a bug report can be pointed at a *copy* without editing code, and it's an environment variable rather than an argument because MCP client configs treat `env` as a first-class field.

### Setup, and what Cheerio doesn't do

Settings shows the helper's path inside this copy of the app and copyable config for Claude Code, Claude Desktop and Codex. It does not write those files. A meeting recorder silently rewriting the configuration of the agent that reads it is the wrong direction of trust, and unrecoverable if the format changes underneath.

stdio only: no socket is opened, nothing listens, and an agent reaches Cheerio only because the client launched the process and holds its pipes. `SPEC.md` carves this out of the "no server component" non-goal on exactly that basis. Diagnostics go to stderr — one stray write to stdout would desynchronize a client's framing.

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

**Notifications are the one permission the walkthrough doesn't ask for**, and that's deliberate (issue #51). `UNUserNotificationCenter` needs no entitlement and no usage string, and its prompt is requested *lazily* — at the first moment `Cheerio/Notifications/NotificationService.swift` would actually post something, which is within half an hour of a real calendar meeting or right after a recording finishes processing. Putting it in the first-run sequence would ask about a feature nothing has demonstrated yet, on top of three dialogs that each gate something visible. A denial is final and silent: nothing retries, nothing badges Settings, and both notifications simply never appear. The one place it's mentioned is Settings › General, where somebody has come looking.

One consequence of the sandbox being off: the missing network entitlement no longer *enforces* anything — entitlements only constrain a sandboxed process. So local-only rests on review, not on the system.

What that means concretely, now that Sparkle is in the app:

- **The invariant is unchanged**: recording and processing a meeting must never need the network. Every model is on the machine, and the diarization model ships in the bundle, so nothing in that path opens a connection. A one-time setup download would be compatible with the invariant; a connection during capture never is.
- **There is exactly one thing in the app that talks to the network**, and it is the updater: `Cheerio/Updates/AppUpdater.swift`. It fetches the appcast from `https://github.com/ObviosCo/cheerio/releases/latest/download/appcast.xml` — a release asset, not the website — and, if the user accepts, the zip from that same release. Nothing else in the app should contain `URLSession`, sockets or `import Network` — that is the line to hold in review, and it is narrower and more checkable than "no networking code".
- **Updates keep out of the way of capture.** `UpdatePolicy` implements `updater(_:mayPerform:)` and refuses *every* check start — scheduled or user-initiated — unless `CaptureSession.state == .idle`; a manual check gets the refusal shown by Sparkle's UI. For scheduled checks Sparkle treats the refusal as a deferral and reschedules, but it also stamps the attempt as the last check, so a vetoed check waits out the next interval rather than retrying when the meeting ends; a vetoed manual check is simply retried by the user. What the gate deliberately does not do is abort a check or download admitted while idle if a recording starts mid-cycle — that stays a documented edge, not machinery.
- **No analytics, still.** Sparkle's system profile would append OS version, CPU, model and language to the feed request. `SUEnableSystemProfiling` is false, `sendsSystemProfile` is set false in code, and the delegate returns no feed parameters and no allowed profile keys. Three refusals for one switch, because the invariant is worth more than the tidiness.
