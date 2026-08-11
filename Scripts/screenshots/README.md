# Scripts/screenshots

Takes the app's picture. Same seeded demo store for the website's imagery and for
looking at a change you can't read off a diff.

```sh
./Scripts/screenshots/capture.sh     # → Scripts/screenshots/out (gitignored)
./Scripts/screenshots/publish.sh     # → site/img, for the four the site uses
```

## Two ways to take it

There are two capture paths, and they share everything except the shutter.

| | Local (`capture.sh`) | CI (`.github/workflows/screenshots.yml`) |
| --- | --- | --- |
| Runs | on your Mac, when you ask | on `macos-26`, on every PR touching `Cheerio/Views/**`, `Cheerio/*.swift` or `site/**` |
| Shutter | `screencapture -l<window>`, via `capture-window.swift` | `XCUIElement.screenshot()`, in `CheerioScreenshotTests` |
| Needs | Screen Recording granted, a Retina display, a logged-in session | nothing granted; a runner has nobody to grant it |
| Output | `-1x`/`-2x` pairs in `out/`, for `site/index.html`'s `srcset` | one capture per surface plus a width-capped `-preview`, on the `screenshots` branch |
| Good for | publishing the site's imagery, and iterating with your own eyes | **PR previews — this path is the authoritative one** |

Both seed the same store, through the same `seed-store.sh`, and both reach the states
they photograph through the same `ScreenshotMode` launch arguments.

A third consumer shares the seeder and the launch arguments without taking pictures
at all: `CheerioAccessibilityTests` (scheme `CheerioAccessibility`, run by
`.github/workflows/accessibility.yml`) audits the same screens for accessibility —
contrast first — in both appearances, via `-screenshotAppearance`. It's a sibling
bundle rather than more tests in `CheerioScreenshotTests` because the two have
opposite failure semantics: capture is capture-and-continue, an audit finding must
go red, and a red audit must never stop screenshots from being captured. Only the shutter
differs, and it differs because a GitHub runner has nobody to grant Screen Recording
to: denied, `screencapture` hands back a solid black frame rather than an error. A UI
test's own screenshot API isn't reaching into another process's window, so it isn't
gated that way.

**CI is what a reviewer should be looking at.** A capture posted to a PR came off the
branch's code on a machine with no local state, which is the property that makes it
evidence. `capture.sh` is for the site and for your own eyes; when the two disagree,
the runner is right about what the branch does.

What CI does with them: pushes the PNGs to an orphan `screenshots` branch under
`pr-<number>/<sha>/`, then posts (or edits) one sticky comment embedding them from
`raw.githubusercontent.com` — which works because this repo is public. That branch is
**disposable history**: it shares no commit with `main`, nothing on it is ever merged,
no workflow watches it, and `git push origin --delete screenshots` is a supported move
because the next run makes a new one. Each PR keeps one directory (a new run replaces
the last), and closed PRs' directories are pruned, so the *tip* stays small; the
objects behind old commits are what deleting the branch is for.

### Two workflows, because one of them can't be trusted

Capturing and publishing are deliberately separate:

- **`screenshots.yml`** runs on `pull_request` and holds **`contents: read` and
  nothing else**. Everything it executes — `bootstrap.sh`, the seeder, the test
  bundle, every script in `ci/`, and that workflow file itself — is code from the pull
  request, which by definition nobody has reviewed yet. A write token here would be a
  write token any contributor could spend by editing one of those files. So it
  captures, and uploads a `screens` artifact: the PNGs plus a `metadata.json` naming
  the pull request and the head commit.
- **`screenshots-publish.yml`** runs on `workflow_run` when that finishes. Because
  `workflow_run` runs in the *base repository's* context from the *default branch's*
  checkout, the scripts it executes are the reviewed, merged ones, and it can safely
  hold `contents: write` and `pull-requests: write`.

The artifact crosses that line, so it's treated as hostile: `ci/verify-handoff.sh`
refuses anything that isn't a flat, plausibly-named file with a real PNG header,
caps the count and the bytes, and copies only what passed into a clean directory that
the publish scripts read instead of the download. The pull request number and head SHA
come from the `workflow_run` payload — `metadata.json` is allowed to agree with it and
nothing more.

Consequences worth knowing. A pull request that changes the publishing half is
publishing with the *old* half until it merges, which is the price of the base-branch
checkout. And a `workflow_run` job's status doesn't appear as a check on the pull
request: the PR's check is **Screen previews**, and it goes red when a surface didn't
come out; the publish job's evidence is the comment.

The pieces, in the order they run:

| File | Job |
| --- | --- |
| `seed-store.sh` | Writes the demo store into a scratch home. Shared with `capture.sh`. |
| `CheerioScreenshotTests/` (repo root) | Launches the app once per surface and attaches the picture. |
| `ci/extract-screenshots.sh` | Pulls the attachments out of the `.xcresult`, restores their real names, writes the previews. |
| `ci/check-captures.sh` | Fails the capture job when a surface is missing — the expected set is read out of the test file, so there's no second list to keep in step. |
| — the artifact crosses the trust boundary here — | |
| `ci/verify-handoff.sh` | Validates it, and works out which pull request (if any) this run may publish for. |
| `ci/publish-branch.sh` | Commits the captures to the `screenshots` branch, prunes, enforces the ~10 MB budget. |
| `ci/render-comment.sh`, `ci/post-comment.sh` | Build the comment and post or edit the one already there. |

A PR **from a fork** isn't published. The token would allow it now — the publish half
runs in the base repo either way — but a fork's captures were rendered by unreviewed
code, and the repository's own branch and comments aren't the place to find that out.
Nothing fails: the captures are attached to the capture run as an artifact, and both
job summaries say so.

Running the UI tests by hand is possible (`xcodebuild test -scheme CheerioScreenshots`
after `./Scripts/screenshots/seed-store.sh`), but it drives your GUI for a couple of
minutes and, unlike `capture.sh`, doesn't put your preferences back afterwards. On
your own machine, prefer `capture.sh`.

`capture.sh` builds the app by default (`--skip-build` to reuse the last one while
iterating on the harness itself, `--app <Cheerio.app>` to point at a build of your
own — that one's never rebuilt), seeds a store full of invented meetings, and
launches the app once per shot. It takes two or three minutes and needs a logged-in
graphical session — it is photographing real windows, not rendering views offscreen.

**Local runs need Screen Recording permission**, granted to whatever process invokes
the script — your terminal, most likely. `screencapture -l<window>` of another
process's window is itself gated by that TCC permission, on a fresh machine or a
runner nobody's granted it to yet; denied, macOS hands back a full-size, solid black
frame rather than an error. `capture-window.swift` samples the captured pixels and
refuses to write out a suspiciously blank result, so a missing grant fails loudly
(naming Screen Recording) instead of quietly publishing a black square. Grant it once
in System Settings → Privacy & Security → Screen Recording and it's done for good.
The CI path captures through XCUITest instead, which isn't gated by Screen Recording
the same way — its screenshots come from the test host, not from `screencapture`
reaching into another app's window.

**Publishing needs a Retina display.** Captures are labelled `-2x` and then halved by
the shell into the `-1x` half of the `srcset`; on a native-1x display the "2x" file
is actually 1x, and halving it again would publish a mislabeled 0.5x asset.
`capture-window.swift` checks the capture's pixel size against the window's point
size and fails, naming the mismatch, rather than let that through.

## What it produces

| File | What's in it |
| --- | --- |
| `library` | The library with the richest meeting selected — notes, action items, follow-ups, speakers |
| `library-transcript` | A shorter meeting, so the attributed transcript is on screen under the notes |
| `library-empty-state` | Nothing selected — the empty-state dashboard (#124): upcoming events, this week's activity, the two start actions, a rotating tip |
| `onboarding-welcome` … `onboarding-finish` | All seven walkthrough steps, in order |
| `settings-participants`, `settings-updates`, `settings-callback` | Three of the six Settings tabs — the site uses these three; CI shoots all six |
| `settings-participants-confirmed` | The same tab with `VoiceEnrollmentRecorder`'s post-save acknowledgment (issue #128) forced on via `ScreenshotMode` — nothing here saves a real sample, so this is the only way that state gets photographed |

Each one twice: `<name>-2x.png` straight off the Retina display, and `<name>.png`
at half that, which is the 1×/2× pair `site/index.html`'s `srcset` wants.

The CI pass shoots a different, overlapping set: `library`, `library-transcript`,
`library-empty-state`, all six Settings tabs, `settings-participants-confirmed`, and
`onboarding-welcome` — one test per surface in `CheerioScreenshotTests`. It also shoots
`library-empty-state-no-enrollment`
against a second seeded store (`seed-store.sh --skip-enrollment`) — meetings exist, but
nobody's enrolled, so issue #125's voice-enrollment prompt is on screen too, on top of
the rest of the dashboard rather than in place of any part of it. `capture.sh` doesn't
reproduce that one locally; it would mean seeding and
launching against a second scratch home for a single shot the CI path already covers.
It doesn't walk the whole walkthrough (seven launches to show what one screen already
tells a reviewer), and it labels nothing `-2x`: a GitHub runner's display is 1x, so
there's no second scale to name, only a width-capped `-preview` copy for the comment
with the full-size file behind the link.

## The three things worth knowing

**Your data is never in shot.** The app is launched with `CFFIXED_USER_HOME` pointed
at a scratch directory, which is what relocates `~/Library/Application Support` and
the SwiftData store inside it. `HOME` on its own does **not** — Foundation resolves
the home directory through CoreFoundation, which reads `CFFIXED_USER_HOME` and
ignores `HOME`. (Both are set, because things that shell out read the latter.)

Preferences are the exception: they go through `cfprefsd`, which resolves the domain
by uid and writes to your real preferences whatever the environment says. So
`capture.sh` exports the app's preferences before it starts and imports them back
afterwards, and everything it needs the app to *read* is passed as a launch argument
— the argument domain, which is read-only and dies with the process.

Windows are found by the pid of the process the script started, so a real Cheerio
running at the same time is never captured and never killed.

**The demo store is invented.** `SeedDemoStore/` is a small executable that depends
on `CheerioKit` by path, so the store it writes is the schema the app is about to
open. Seven meetings, four enrolled voices, one of them marked "me", timestamps
spread over the last three weeks. Its action items are built by passing drafts
through `ActionItem.resolved(from:ownerNames:)` — the only public way to make one —
so the notes in a screenshot can't show a trust state the app would never produce.

Change what's in the pictures by editing `SeedDemoStore/Sources/SeedDemoStore/main.swift`.
Nothing in there may ever come from a real meeting: these get published.

**Nothing clicks the app.** Every state the harness needs is reached by a launch
argument, read in `ScreenshotMode` in the app target:

| Argument | Effect |
| --- | --- |
| `-screenshotSelectMeeting <n>` | Opens the library with the nth meeting selected |
| `-screenshotWindowSize 1440x900` | Sizes the library window |
| `-screenshotOpenSettings YES` | Opens Settings (the tab comes from `-com_apple_SwiftUI_Settings_selectedTabIndex`) |
| `-screenshotOnboardingStep <n>` | Opens the walkthrough on step *n* |
| `-screenshotExpandTranscript YES` | Opens the detail view's transcript disclosure, which otherwise starts collapsed (#104) — only `library-transcript` needs it |
| `-screenshotVoiceEnrollmentConfirmed YES` | Shows `VoiceEnrollmentRecorder`'s post-save acknowledgment instead of its empty form — only `settings-participants-confirmed` needs it |

This is not the obvious design — the obvious one drives the real UI with AppleScript
or XCUITest — and the launch-argument hooks exist because reaching a *state* this way
needs no permission at all, unlike the alternatives:

- Synthetic input (`CGEventPost`, System Events, `cliclick`) needs the *automating*
  process to hold macOS Accessibility permission. Without it the events are dropped
  silently: the script reports a click and nothing happens.
- XCUITest needs developer mode enabled (`DevToolsSecurity -enable`), which is an
  admin-password prompt, on top of whatever the test target itself needs granted.

Reaching the state needs nothing, and it's also more repeatable — there's no click to
land, no window that moved. Getting a *picture* of that state is a separate problem,
and this harness still pays for it: `screencapture -l` of another process's window
needs Screen Recording permission granted to whoever's invoking the script (see
above). That's a one-time grant on a machine a person is sitting at, but not
something a fresh clone or a CI runner has — which is why the CI path captures through
XCUITest instead: a test host's own screenshot API isn't reaching into another app's
window the way `screencapture` is, so it isn't gated by Screen Recording, only by the
developer-mode grant above, which a GitHub runner image already has.

Note that the CI path uses the same launch arguments rather than clicking through the
UI. It could click — it's a UI test, it has the accessibility handle — and it
deliberately doesn't: the argument gets to the state in one launch with nothing to
wait for, and the point of the pictures is to show what a screen looks like, not to
prove it can be navigated to.

What it costs: the harness photographs states it *put* the app in, so it can't catch
a bug in getting to them. A walkthrough step that renders correctly but can't be
reached still photographs fine. That's a real gap, and it's the reason to keep
pressing Continue by hand once in a while.

## Permissions and recordings

The three permission steps are photographed in their explain state — the harness
never presses the button that asks macOS for anything, and nothing in it can start a
recording. Update checks are switched off through Sparkle's own defaults, so the
Updates tab photographs with both toggles off; that's the harness, not the default.

## When something doesn't come out

- **A tiny, skewed 200×218 image.** The window was captured while the app wasn't
  frontmost, and with Stage Manager on that's the thumbnail in the side strip.
  `capture-window.swift` activates the app and waits before shooting; if you're
  writing a new shot, keep that order.
- **The wrong window.** Settings takes the selected tab's name as its window title
  and the walkthrough is titled "Welcome to Cheerio", which is what
  `--title-contains` matches on. The library window's title is always "Cheerio" —
  the detail view no longer sets its own `navigationTitle` (#104, one title instead
  of two) — so don't match it by title regardless.
- **An empty detail pane.** `-screenshotSelectMeeting` is 1-based and indexes the
  sidebar's order, newest first.
- **"came back a solid black frame" / "Screen Recording".** The process invoking
  this script hasn't been granted Screen Recording. Grant it in System Settings →
  Privacy & Security → Screen Recording and re-run; there's no retrying past it.
- **"requires a Retina display" / a scale under 2x.** The display capturing this ran
  at native 1x. Run the harness on a Retina display — the failure is deliberate,
  to stop a mislabeled 0.5x asset from reaching `site/img`.
