# Cheerio — Design Handoff

A brief for a designer joining the Cheerio project. Four tracks: **app icon**, **brand identity and voice**, **UI review + improvement**, and a **website**.

Read the [README](../README.md) first — it describes what the app does today, what's verified, and what's broken. Then [SPEC.md](SPEC.md) for scope and [ARCHITECTURE.md](ARCHITECTURE.md) for how it works. This document is the design-side counterpart to those, and the only one written for someone who isn't going to read the Swift.

---

## 1. What Cheerio is

An open-source AI meeting-notes app for macOS. Think Granola, but free, single-user, and self-contained: transcription runs on Apple's on-device `SpeechAnalyzer`, summarization on the on-device Foundation Model, speaker identification on a Core ML model on the Neural Engine. No accounts, no subscription, no meeting bot joining the call.

Because every model is on the machine, the app works on a plane, doesn't slow down when someone else's API does, and doesn't change behaviour the week a hosted model is swapped underneath it. (Not that it's frozen — these are Apple's frameworks, and Apple ships OS updates. It just doesn't move without you.) That's a genuinely nice property and it's worth mentioning — but it is **not** the pitch, and the design shouldn't be built around it. The pitch is that it's a good meeting-notes app you own outright.

**Who it's for:** individuals who take a lot of meetings and want good notes without a subscription or a bot in the call. Single-user by design — no teams, no sharing.

**The core loop:**

1. Meeting starts → user hits record, from the sidebar or the menu bar (mic + system audio, no bot).
2. A rough-notes scratchpad on top, live transcript below, labelled Me/Them.
3. Meeting ends → speaker identification runs over the recorded audio and replaces Me/Them with real names where it can; the local model merges rough notes + transcript into structured notes.
4. The user corrects any speakers the model got wrong, and those corrections stick.
5. Notes live in a searchable library, exportable as Markdown.

**Positioning words to design against:** quiet, fast, unfussy, self-contained, native-feeling. It should feel like a well-made Mac utility, not a startup SaaS product — and not like a security tool either. No padlocks, no shields, no vault imagery.

**Explicit non-goals:** no dashboards, no team/collaboration surfaces, no usage analytics or engagement mechanics, no onboarding funnel, no upsell. Any design that implies a server exists is wrong.

### Current state

The app **builds, runs, and records real meetings**. This is no longer a paper project — you can install it and use it, and you should before designing anything.

The README's [Current status](../README.md#current-status) table is the authority. The short version: an in-person two-person recording labelled 9 of 9 segments to the right speaker, including 1–2 second alternating turns. A live video call has never been tested. And there's a known bug where the mic hears your speakers, so remote participants land in *both* channels and the transcript duplicates itself — use headphones.

The UI is developer-built and functional rather than designed. Some of it has already been through a round of usability fixes and is reasonable; none of it has had a designer's eye.

**The app icon shipped in [#15](https://github.com/ObviosCo/cheerio/pull/15)** — a copper ring on a deep navy gradient, rendered by `Scripts/render-appicon.swift` into a flat `AppIcon.appiconset`. That settles the palette's starting point (see §3) and part of Track A. There is still no wordmark, no type choice, no color system beyond the icon's four values, and no website.

### Constraints that shape everything

- macOS 26 (Tahoe)+ only, Apple Silicon. We can use the newest platform APIs and design language without back-compat compromises.
- **App Sandbox is off, permanently.** A sandboxed process tap returns success at every step and then reads pure digital silence — no error, no prompt. This is documented in ARCHITECTURE.md as a do-not-revisit. The consequence for you: **Cheerio cannot ship on the Mac App Store.** Distribution is direct download, which changes what presentation assets matter (see §8).
- **At most four speakers** can be resolved per audio channel. That's a hard model limit and it leaks into the UI in several places — see §4.
- **If you do state the offline property, state it precisely.** Nothing needs the network to record, transcribe or summarize a meeting — that is the claim, and it holds in airplane mode. What is *not* true, since automatic updates landed, is "there is no networking code in the app": Sparkle fetches an update feed once a day and a zip if the user accepts one, and macOS itself fetches the speech model for your locale on first run. The README's [No service required](../README.md#no-service-required) section has the exact wording. Say it once, plainly, where it's useful; don't round it up into a promise the app can't make.
- MIT licensed, public repo. Every asset delivered must be redistributable — see [Licensing](#8-licensing-and-asset-hygiene).
- Solo/small maintenance. Prefer a system a developer can extend without the designer in the loop over a set of hand-tuned one-off screens.

---

## 2. Track A — App icon

**Mostly shipped.** [#15](https://github.com/ObviosCo/cheerio/pull/15) landed a copper ring on a deep navy gradient: the name is already a shape (the cereal, the final *o*, quietly a record ring), it's one geometry at every size, and it holds together at 16 px where illustrative concepts fall apart. That satisfies the "lean into the name, subtly" direction in §10.

Two things about how it's built, because they change how you'd revise it:

- **It's generated, not drawn.** `Scripts/render-appicon.swift` is a CoreGraphics script that writes all ten `AppIcon.appiconset` slots. The PNGs are build artifacts — never hand-edit them; change the script and re-run `swift Scripts/render-appicon.swift`.
- **Per-size optical corrections, not proportional scaling.** Below 128 px the ring thickens (17 → 21 units of 100) and the faint navy ink-edge hairlines drop out, so small slots read crisp rather than spindly. The masters are deliberately not the same drawing at different sizes.

### What's left

| Asset | Format | Use | Status |
| --- | --- | --- | --- |
| App icon, flat set | `.appiconset` PNGs | The app itself | **Done** (#15) |
| Icon Composer bundle | `.icon` (layered) | Light / dark / clear / **tinted** variants | Not done — see below |
| Monochrome mark | SVG | Menu-bar item, favicon, docs | Not done |
| Social preview | PNG 1280×640 | GitHub repository card | Not done |
| DMG / download presentation | See §8 | Direct distribution | Not done |

The **`.icon` bundle** is the notable gap. macOS 26 masks every icon into its own squircle and offers four appearance variants; the flat set is fully valid and renders correctly, but it doesn't participate in the layered treatment. Tinted mode is the one that would test the mark hardest, since it strips colour and the copper-on-navy contrast is doing real work. Treat this as a polish pass, not a rebuild — the geometry is settled.

The **monochrome mark** matters more than its row suggests: it's the menu-bar item, and §10 makes the menu bar the app's front door.

### Menu-bar icon — now a first-class surface

The app already ships a `MenuBarExtra` ([CheerioApp.swift:35](../Cheerio/CheerioApp.swift#L35)) that can start and stop a recording without surfacing the window. Mid-call, it's the primary interface. It currently uses stock SF Symbols as placeholders, one per session state:

| State | Placeholder symbol | What it means |
| --- | --- | --- |
| `idle` | `waveform` | Not recording |
| `preparingModel` | `arrow.down.circle` | Getting ready. Entered on **every** start, not just the first — usually a blink, but long and silent on first run while macOS downloads the speech model |
| `recording` | `record.circle.fill` | Capturing right now |
| `finishing` | `ellipsis.circle` | Generating notes and identifying speakers |

Design **all four** as template images: single-color, transparent, on an 18×18pt grid, legible at 1x, working against light and dark menu bars and with system tinting. They should be recognizably related to the app icon without being a shrunken copy of it, and — critically — `recording` must be unmistakable at a glance from across a screen. See design question 4 in §4.

---

## 3. Track B — Brand, identity, and voice

Deliberately lightweight. This is an open-source utility, not a company. What we need is enough of a system that the app, the README, and the website look like one thing.

**Deliverables:**

1. **Wordmark / name treatment.** "Cheerio" set in something with character but not costume. SVG, with a lockup (mark + wordmark, horizontal and stacked) and clearance rules.

2. **Color palette.** Small, but it has more work to do than a typical app palette. The starting point is no longer open: the shipped icon anchors it at **navy** `#1E2B3F`→`#35496B` and **copper** `#A87040`→`#D49E6C`. Build outward from those rather than proposing a new accent — the icon is in the Dock now and the rest of the system should agree with it. It needs:
   - A primary accent, derived from the icon's copper.
   - Neutrals, surfaces, and borders that sit with the navy without turning the app into a dark-blue product. Most of the app is a text-heavy light-or-dark reading surface; the brand colours are punctuation.
   - **A speaker identity system.** This is the interesting one. The transcript labels speakers, and depending on the meeting a label can be `Me`, `Them`, `Speaker 2`, or a real enrolled name — up to four resolved per channel. Right now everything is hardcoded blue for the mic channel and gray for the system channel ([MeetingDetailView.swift:172](../Cheerio/Views/MeetingDetailView.swift#L172)), which means two different named people on the same channel look identical. Design a categorical, colorblind-safe way to distinguish speakers that degrades gracefully when there's only one, and that doesn't turn a transcript into a highlighter accident.
   - **A "model said" vs. "you said" distinction.** Hand-corrected speaker labels are currently marked with a 7-point `hand.raised.fill` glyph. Provenance matters here — this app asks the user to correct a model and promises the corrections survive — and it deserves a real treatment rather than a tiny icon.
   - Warning/attention states. Several already exist in orange (sample too short, duplicate name, over the speaker cap) and need to be part of the system rather than ad hoc.
   - Recording state, which must never be ambiguous.

   All colors need light and dark values, delivered as **named Color Set entries for `Assets.xcassets`** so code references semantic names, not hex.

3. **Typography.** Strong recommendation: **use the system font (SF Pro / SF Mono)** and give us a type scale mapped to SwiftUI's semantic styles rather than a custom face. It costs nothing, supports Dynamic Type, and makes the app feel native — and because macOS supplies it through system APIs, nothing ships in the repo or the bundle. Note that this is *not* the same as redistributable: Apple's license covers using the system font on Apple platforms, not shipping the font files. Never hand us SF Pro or SF Mono files to bundle. A display face is fine for the wordmark, the README, and the website (§5) — anywhere outside the app binary — provided it's OFL or similar and genuinely redistributable. It must never be required to run the app.

4. **Voice — and a copy edit.** The app has a *lot* of prose in it, and much of it is genuinely good: it explains constraints where the user hits them, in plain language ("Have them talk naturally for about 30 seconds — read something aloud if it helps"). The [README](../README.md) is the closest thing to an established register — direct, specific, willing to name what doesn't work — and is worth reading as a voice reference before you write any UI copy.

   Two jobs. First, the ordinary one: set the register for the app itself and give us five or six rewritten examples. Second, the harder one: **the UI currently explains itself constantly**, because the model underneath is complicated — a four-voice cap, per-meeting rosters, samples that can be too short, corrections that outrank the model. Nearly every control carries a caption defending it. Some of that explanation should become structure, progressive disclosure, or better defaults instead of more text. Deciding which is a design problem, not a copywriting one.

5. **The voice, written as a skill we can run.** Not just a style page — a `SKILL.md` that lives in the repo (`.claude/skills/cheerio-voice/`) and lets an agent write in Cheerio's voice without you in the room. Release notes are the first and most frequent job: this is a solo-maintained open-source project that will ship versions for years, and every release needs notes that sound like the same product. The same skill should cover README edits, website copy, commit-adjacent prose, and UI microcopy.

   What makes a voice skill work is specificity that survives paraphrase: not "be clear and friendly," but the actual rules — sentence case, no exclamation marks, name the thing that broke, don't say "we're excited to announce," how to write a release note for a bug fix versus a feature versus a breaking change, with real before/after examples drawn from this repo. Include the anti-patterns; they carry more signal than the positives. Ship it with three or four worked examples an agent can pattern-match against.

   If a second skill earns its place, it's a UI-microcopy one — the constraints there are different enough (length limits, no room to explain, the caption-density problem above) that folding it into the release-notes voice would blunt both.

6. **README / repo presentation.** The README was rewritten recently and reads well; it has no visual identity at all. A hero image or icon banner and a light styling pass. Along with the website, this is the top of the funnel.

**Out of scope for now:** App Store screenshots (ruled out entirely — see §1), merchandise, motion/brand animation.

---

## 4. Track C — UI review and improvement

The most open-ended track, and after the icon the most valuable. Everything below exists and runs today.

### What exists

| Surface | File | What it is |
| --- | --- | --- |
| App shell | [CheerioApp.swift](../Cheerio/CheerioApp.swift) | Three scenes: main `Window`, `MenuBarExtra`, `Settings`. Split view; selection lives in the detail column. **Window-first today — §10 says this should invert** |
| Library sidebar | [MeetingListView.swift](../Cheerio/Views/MeetingListView.swift) | Start/stop controls, a live calendar-event offer, elapsed timer, `.searchable` search, flat reverse-chronological list |
| Live recording | [RecordingView.swift](../Cheerio/Views/RecordingView.swift) | Editable title + roster menu + timer header; `VSplitView` with notes on top (ideal 460pt) and transcript below (ideal 180pt) |
| Meeting detail | [MeetingDetailView.swift](../Cheerio/Views/MeetingDetailView.swift) | Header, rendered Markdown notes, rough notes, "Re-identify speakers", speakers panel, expanded transcript with a per-line speaker menu, Export |
| Speakers panel | [MeetingSpeakersSection.swift](../Cheerio/Views/MeetingSpeakersSection.swift) | Per-meeting speaker list with line/duration counts, rename-or-merge menu, "Use as voice sample" |
| Roster menu | [ParticipantRosterMenu.swift](../Cheerio/Views/ParticipantRosterMenu.swift) | "Who was here" — picks which enrolled voices get primed, with an over-cap warning |
| Settings → Privacy | [SettingsView.swift](../Cheerio/Views/SettingsView.swift) | Audio retention picker (none / 24h / 7d / 30d / forever), "Delete audio now" |
| Settings → Participants | [ParticipantsView.swift](../Cheerio/Views/ParticipantsView.swift) | Enrolled voices, "This is me", remove, and a 30-second guided voice-sample recorder |
| Menu bar | [MenuBarView.swift](../Cheerio/Views/MenuBarView.swift) | Start/stop, current calendar event, open window |

### What does not exist

The README's [Known issues](../README.md#current-status) and [Roadmap](../README.md#roadmap) cover the engineering side of this list; below is what it means for design.

- **Guided first run.** There *is* an empty state — a `ContentUnavailableView` saying "Select a past meeting or start recording" — so it isn't a blank window. What's missing is everything that would set someone up to succeed: enrolling a voice before the first meeting rather than after, explaining what the two audio channels are, and getting the permissions in place before a recording is already running.
- **First-run model download UI.** The transcription model downloads on first use; the UI for it is the words "Preparing model…" with no progress and no size estimate.
- **System-audio and calendar permission handling.** Microphone has a real recovery path (an alert that deep-links into System Settings). The other two have nothing — and system audio is the one users won't understand.
- **Audio playback.** Audio is recorded and retained but there's no way to hear it.
- **Recording modes** (solo / in-person / video call), designed but unbuilt. Both channels always run today, and that's the right default — see §10, which corrects an earlier assumption about this. What modes would actually change is echo cancellation.
- **In-room vs. remote per participant** — see design question 3.

### The design questions that matter

Roughly in priority order.

1. **Speaker identity is now the central design problem, and it has a seam in it.** During recording, every line is labelled `Me` or `Them` by which audio channel it came from. Names only appear *after* the recording stops, when identification runs over the saved audio. It's a v1 non-goal in [SPEC.md](SPEC.md) and a documented gotcha in [ARCHITECTURE.md](ARCHITECTURE.md#diarization).

   The failure mode is bad: in an **in-person** meeting everyone is on the microphone, so every live line reads "Me," and it looks exactly like the app is broken. Then the meeting ends and it silently becomes correct. The live transcript needs to set the right expectation about what it is and what's coming, without nagging. This is the single most valuable thing you could solve.

   One caveat worth designing around: real-time speaker naming is a **v2 candidate**, not a permanent constraint. If it lands, the seam closes. Prefer a solution that degrades into the seamless case rather than one built around the gap as a permanent feature.

2. **The four-speaker cap, and the roster UI built to manage it.** The model resolves at most four speakers per channel, so priming a voice that wasn't in the room costs a slot someone real needed. The current answer is a "Who was here" menu per meeting with toggles, an over-cap warning triangle, and a tooltip explaining which voices got dropped and which were kept. It is a coherent solution to a genuine constraint, and it is also an implementation detail wearing a UI. Can this be made comprehensible — or largely invisible, with good defaults and an escape hatch — rather than explained?

3. **Voice enrollment.** Getting names instead of "Speaker 2" requires enrolling voices: roughly 30 seconds of someone talking. There are two entry points today — a form in a Settings tab, and "Use as voice sample" on a speaker in a finished meeting, which lifts their audio out of that recording. The second is the better idea and is currently the less prominent one. Neither is a flow; both are forms. There's also a "This is me" designation that pins one voice as the user. Design the path from "I just recorded a meeting with three strangers" to "future meetings name them."

4. **The menu bar becomes the front door, and the recording indicator lives there.** §10 settles the direction: menu-bar-first, with the window as the library. So this question is really two.

   The **IA**: what a menu that has to open fast and stay small can hold — starting a recording, the calendar offer, stopping, and what else? What forces the window open, and what deliberately doesn't? The keyboard path matters here; a global shortcut that starts a meeting without touching the mouse is the logical end of "fastest way to start."

   The **state**: the user must never be uncertain whether Cheerio is recording — this is a trust product and ambiguity is a serious failure. Three places say so today (the menu-bar symbol, the sidebar's red Stop button with an elapsed timer, and the recording view) and they share no visual language. The menu-bar symbol now carries the most weight, because it's the one that's always visible.

5. **The correction model, and making "your edit stuck" legible.** There are two levels of correction: rename a whole speaker across a meeting, or fix a single misattributed line via a menu on the label. Hand corrections outrank the model and survive re-identification. The current signal that a line was hand-corrected is a 7-point icon next to the label. Users need to trust that their edits persist — that's the promise the feature makes — and right now that promise is nearly invisible.

6. **The meeting detail view is a long vertical stack.** Header, notes, rough notes, a re-identify button with an explanatory caption, a speakers panel, a divider, and a transcript that's expanded by default and can run to hundreds of lines each carrying its own menu. Everything is at the same altitude. This needs information architecture: what's the primary read, what's reference, what's a tool.

7. **The live recording layout, and the Markdown scratchpad.** The layout has been through one revision — it started as a 50/50 horizontal split and is now vertical with the scratchpad dominant, on the reasoning that typing is the job and the transcript is glanceable reference. Worth a second look: whether 180pt of transcript is useful or vestigial, whether it should be collapsible, and how the whole thing behaves in a narrow window parked beside a Zoom call, which is the common case.

   §10 also settles that the scratchpad accepts and renders **Markdown**. That's a design problem in its own right and it lands squarely in the middle of this view: the person typing is half-attending and writing fragments, so neither raw syntax nor full WYSIWYG is right. What does a heading, a bullet, or a checkbox look like the instant after it's typed?

8. **Volatile text.** Live transcription emits provisional text that gets revised as the model hears more, currently rendered at 50% opacity and replaced in place. It's the most visually unsettled thing in the app. It needs a treatment that reads as "still listening" without twitching.

9. **Four different kinds of waiting.** Model download on first run, note generation after stopping, speaker re-identification on demand, and the 30-second enrollment recorder (the only one with real progress feedback — it has a `ProgressView` and a live countdown, and it's the best-handled wait in the app). The other three are text labels. Note that these can also *fail*: summarization can fail and fall back to transcript-only, and identification can fail if the audio has been purged by the retention policy.

10. **Permissions.** Three prompts, and they don't matter equally. **Microphone** is required for everything and is the only one with a recovery path today. **System audio** is the unfamiliar one, and it's what captures anything coming out of the machine — the far end of a remote call, but also whatever's playing while you record alone. Denying it costs you every remote participant and quietly narrows what a solo recording captures. **Calendar** is genuinely optional; without it recordings just get timestamp titles instead of event names. Design the pre-prompt explanation and the recovery state for each, and let the stakes differ — asking for all three with equal urgency at launch would be the wrong answer.

11. **Audio retention, which is a real control and currently a bare picker.** How long recorded audio sticks around — immediately, 24 hours, 7 days, 30 days, forever — plus a "Delete audio now" button, sitting in a Settings tab with an explanatory caption. It's worth designing properly because deleting the audio has a consequence the UI doesn't yet connect: once it's gone, speakers can't be re-identified and "Use as voice sample" stops working. That relationship should be visible at the moment of choosing, not discovered later.

    The tab is currently titled "Privacy," and one caption in it carries the app's only statement about being local. Both are fine as far as they go; neither needs amplifying into a theme.

12. **The library.** A flat reverse-chronological list with search over titles, notes, and transcripts. Won't survive a few hundred meetings. Consider grouping, what a row shows beyond title and timestamp (duration? speakers? whether notes generated?), and whether today's calendar deserves a surface.

13. **Empty and degraded states.** Several exist and none are designed: no meetings yet, no search results, no enrolled voices, no transcript, no enhanced notes, audio deleted by retention (which disables "Use as voice sample"), and a meeting that never finished recording because the app quit mid-session.

### Non-negotiables for this track

- **Native macOS, using SwiftUI's vocabulary.** Standard toolbars, sidebar, split views, `Settings` scene, `MenuBarExtra`, menus, focus and keyboard behavior. A design that fights SwiftUI costs disproportionate implementation time and drifts on the next OS release. Flag any deliberate departure so we can price it.
- **Light and dark mode**, both fully specified.
- **Accessibility is a hard requirement**, not a polish pass: WCAG AA contrast, full VoiceOver labelling (the transcript, speaker labels, and recording state especially), Dynamic Type, Increase Contrast and Reduce Motion honored, and **no state communicated by color alone** — this bites twice here, on the recording indicator and on speaker identity.
- **Window resizing.** Specify small-width behavior; a narrow window beside a video call is a primary use case.

---

## 5. Track D — The website

Because there's no App Store listing, the website *is* the product page: where someone lands from a link, decides whether this is for them, and downloads a build. It also has a second job the App Store would normally do — telling people what changed in each release.

**It lives in this repo and ships on GitHub Pages.** That's a real constraint: **the site must be static.** No server, and no build step that can't run in CI.

Two smaller preferences, offered as engineering defaults rather than principles. Keep third-party requests low — self-hosted fonts and no embedded scripts mean fewer things that can break, go slow, or disappear, and the whole site stays reviewable in a pull request. And no analytics, which is an existing repo rule (see the README's Contributing section), not a new one for you.

Worth being clear, because an earlier draft of this brief got it wrong: the app barely touches the network because every model runs on the machine, which is a *consequence* of how it's built, not a values position. Don't carry it over to the website as one. A website makes network requests; that's what a website is. (The app's update feed is an `appcast.xml` attached to each GitHub Release, generated by CI — the site doesn't serve it, and it isn't something to design around.)

Where it lives is a decision for us, not you, but it affects your file layout so it's worth naming: Pages can serve from `/docs` on `main` (which already holds the Markdown docs, so Jekyll would pick those up too), or from a `site/` directory published by an Action. Propose what suits the design; we'll wire it up.

### Pages

Start small. A site this project can maintain beats a site it can't.

1. **Home.** What it is, who it's for, what it looks like, and a download button. The screenshot carries most of the weight here — which means the UI work in Track C and this page are the same problem seen twice. Be honest in the copy: the app is early, and the README's status table sets a tone worth matching.
2. **Download / install.** How rough the first launch is depends on something we haven't settled: a Developer ID-signed and notarized build opens normally, while an unsigned one puts the user through Gatekeeper's "unidentified developer" wall and a right-click-open. There's no signing set up today. Design for the good case, and ask us before writing any bypass instructions — telling people to work around Gatekeeper is a bad look and may well be unnecessary. This subsumes the DMG presentation described in §8.
3. **Release notes.** One page, one entry per version, permalinked. This is the page that runs on rails for years, so its template matters more than its first instance — and it's exactly what the voice skill in Track B exists to write.

Anything beyond those three (docs, a changelog feed, a page about how the on-device pipeline works) is welcome as a proposal, not an assumption.

### What we need

Real HTML and CSS, not a mockup handed over for someone else to build. Semantic markup, a system font stack or a self-hosted OFL face, light and dark via `prefers-color-scheme`, responsive down to a phone, and it should be legible with CSS disabled. Same accessibility bar as the app: AA contrast, real focus states, alt text, keyboard-navigable.

---

## 6. What we'll give you

- The repo. You'll need macOS 26 and Xcode 26. After cloning, this one command does the fiddly parts — it checks your toolchain, fetches a ~93 MB model that isn't committed, and generates the Xcode project:

  ```sh
  ./Scripts/bootstrap.sh
  ```

  Full instructions, including what to set before first launch, are in the README's [Building](../README.md#building) section.
- A walkthrough of the session state machine (`idle` → `preparingModel` → `recording` → `finishing` → `idle`) and how the three scenes relate.
- **Screenshots of every surface, on demand.** `./Scripts/screenshots/capture.sh` seeds a store of invented meetings, launches the app against a scratch container, and captures the library, all seven walkthrough steps, and three Settings tabs at Retina scale into `Scripts/screenshots/out`. `publish.sh` puts the four the website uses into `site/img`. It's how the images in `site/index.html` were made, it's repeatable, and it needs nothing granted to it — see [`Scripts/screenshots/README.md`](../Scripts/screenshots/README.md), including what it can't catch. Use it to see a change rather than describing one, and re-run it when you change a screen that's on the site.
- **Please design the transcript views against real output.** Record something and look at it. It has no punctuation in places, mis-hears names, revises itself mid-sentence, and — in an in-person meeting — currently labels everything "Me" until you stop. Clean lorem-ipsum dialogue will lead you to the wrong design.

## 7. What we need back

- **Figma file** (or equivalent), organized by flow, light and dark artboards.
- **A component/token inventory** — colors, type styles, spacing scale, repeated components, named so they map onto `Assets.xcassets` color sets and SwiftUI modifiers.
- **Redlines only where we'd otherwise guess.** Don't spec what SwiftUI already decides.
- **Icon deliverables** per §2, including all four menu-bar states.
- **The website as working HTML/CSS**, per §5 — a pull request against this repo, not a mockup.
- **The voice skill** as a `SKILL.md` with worked examples, per §3 — also a pull request.
- **A short written rationale** for how you resolve the live-vs-post-hoc speaker seam (question 1). We'll be living with that one, and it's the decision most likely to be wrong in an interesting way.

Prototypes are welcome but not required. A clear static spec plus a paragraph of intent beats a clickable prototype with ambiguous states.

Two of these deliverables are code that lands in the repo (the site, the skill) and the rest are specs someone implements in Swift. Worth being explicit about which is which as you go, so nothing sits in a Figma file waiting for a developer who thought you were shipping it.

## 8. Licensing and asset hygiene

This is a public MIT-licensed repository, and it ships outside the App Store.

- Every delivered asset must be redistributable under MIT or a compatible license, with **no attribution requirement we can't satisfy in a LICENSE file**.
- No stock icons, no CC-BY-ND, no "free for personal use" fonts, no AI-generated assets whose provenance we can't state.
- SF Symbols may be used **in the app** (that's their license) but **not** in the app icon, the wordmark, or marketing material — Apple's license prohibits that.
- For context on how carefully this is handled, read the README's [License](../README.md#license) section: the speaker model is CC BY 4.0 (© NVIDIA), fetched by script rather than committed (a size decision), with its attribution shipped in `THIRD-PARTY-NOTICES.md` inside every built app. The one third-party dependency (FluidAudio) is Apache-2.0 and pinned exactly. Please hold your assets to the same standard.
- Confirm in writing that the work can be committed to a public repo under MIT, and tell us up front if you want an attribution line — we're happy to give one, we just need it declared rather than discovered.

- **The website inherits all of this.** Anything it embeds — a face, an icon, an image — is redistributable and committed to the repo under a license we can name, same as everything else. See §5.

**Distribution presentation.** Because the App Store is ruled out, the download experience is ours to build: a DMG (background art, window layout, drag-to-Applications affordance), the GitHub release page, and whatever first-launch reassurance a notarized-but-not-App-Store app needs. The website's download page (§5) is the front of this; the DMG is the last step of it. Both are things a normal Mac app would get for free from a store listing.

## 9. Suggested sequencing

1. ~~**App icon**~~ — shipped in #15. What remains from Track A is the monochrome menu-bar mark and its four states, the `.icon` bundle, and the social card. The menu-bar mark is the one worth doing next; the rest can wait.
2. **Color, type, and the token inventory** — including the speaker identity system, which is the part with actual design content in it.
3. **The speaker seam and the live recording screen** (questions 1, 4, 7, 8). The hardest and most valuable problem.
4. **Enrollment and correction flows** (questions 2, 3, 5). Newest surfaces, least designed, and where the app currently over-explains itself.
5. **Onboarding, permissions, and waiting states** (questions 9, 10). Entirely absent, and what makes the app feel finished.
6. **The website and the voice skill** (§5, §3). These can run in parallel with the app work and don't block it — but they need the icon and tokens from steps 1–2, so they can't come first. The release-notes template and the skill that writes into it are worth doing together.
7. **Meeting detail IA and the library** (questions 6, 12, 13). Functional today; improvable without a redesign.
8. **Wordmark, README, DMG.** Nice, not blocking.

## 10. Decisions already made

These were open when this brief was drafted. They've since been settled, and they're binding — design against them rather than reopening them.

- **The palette is anchored by the shipped icon.** Navy `#1E2B3F`→`#35496B`, copper `#A87040`→`#D49E6C`. These come from the studio palette Cheerio shares with its sibling projects, so the family is settled even though the system built on top of it isn't. Don't propose a replacement accent; propose the neutrals, surfaces, states, and speaker colours that live with it.

- **Lean into the name, subtly.** "Cheerio" is a warm, slightly British goodbye and the identity should carry some of that. The constraint is register: **subtle, not campy.** No cereal jokes, no Union Jacks, no winking. The warmth should be something you notice on the second look, not the first. This is the single hardest line to walk in this brief and it's worth showing a range so we can calibrate together.

- **The app should be menu-bar-first.** The `MenuBarExtra` becomes the primary surface, not a convenience mirror of the sidebar. The reasoning is speed: the fastest path to starting a meeting shouldn't require finding a window first. The window becomes the library — where you read, search, and correct — rather than the place you go to begin.

  This is committed scope, not a preference: it's [SPEC.md](SPEC.md) goal 8, with two of the success criteria attached to it. Design against it as a given.

  This is a real IA change and it lands on you. What belongs in a menu that has to stay small and fast, versus what needs the window? Where does the calendar offer live? Does starting a recording open the window, or stay out of your way until you want it? What's the keyboard path? See design question 4, which this now outranks.

- **Recording mode is *not* about disabling the system tap.** An earlier version of this brief said the tap was pointless for solo recording. That's wrong, and it's worth understanding why: input and output can be different devices. Someone recording alone through AirPods still has system audio worth capturing, and the mic isn't picking it up out of the room. Running both channels is the right default, and it stays.

  What that leaves is the narrower question — whether echo cancellation should differ by situation, and whether that's worth asking the user about at the worst possible moment (right as a meeting starts). Prefer inference or a quiet default over a modal choice.

- **The scratchpad should accept and render Markdown.** Plain text is what's built. Markdown is what people expect from a text box now, and rough notes want structure — bullets, headings, the occasional checkbox — precisely because they're written fast.

  Two things make this cheaper than it sounds: `MarkdownBlock` in CheerioKit already parses block Markdown, and `MarkdownNotesView` already renders it for the enhanced notes. The design problem isn't rendering, it's **editing**: what a live-editing Markdown surface looks like during a meeting, when the user is half-attending and typing fragments. Full rich-text WYSIWYG is almost certainly wrong here; so is raw syntax with no feedback. Find the quiet middle.

## 11. Still open

- Whether the enhanced-notes output should be rendered as real structure (summary / key points / decisions / action items as distinct sections) rather than one Markdown blob. Action items are the highest-value thing the app produces and are currently buried in prose. Raised as design question 6; not yet decided.
