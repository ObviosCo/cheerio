# Scripts/screenshots

Takes the app's picture. Same script for the website's imagery and for looking at a
change you can't read off a diff.

```sh
./Scripts/screenshots/capture.sh     # → Scripts/screenshots/out (gitignored)
./Scripts/screenshots/publish.sh     # → site/img, for the four the site uses
```

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
The CI path (issue #61 deliverable 2) captures through XCUITest instead, which isn't
gated by Screen Recording the same way — its screenshots come from the test host, not
from `screencapture` reaching into another app's window.

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
| `onboarding-welcome` … `onboarding-finish` | All seven walkthrough steps, in order |
| `settings-participants`, `settings-updates`, `settings-callback` | Three of the six Settings tabs — `Agents` isn't shot yet; it joins this table once capture runs on CI (issue #61) |

Each one twice: `<name>-2x.png` straight off the Retina display, and `<name>.png`
at half that, which is the 1×/2× pair `site/index.html`'s `srcset` wants.

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
something a fresh clone or a CI runner has — which is why the CI path (issue #61)
captures through XCUITest instead: a test host's own screenshot API isn't reaching
into another app's window the way `screencapture` is, so it isn't gated by Screen
Recording, only by the developer-mode grant above.

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
  `--title-contains` matches on. The library window's title is the *selected
  meeting's* name, so don't match it by title.
- **An empty detail pane.** `-screenshotSelectMeeting` is 1-based and indexes the
  sidebar's order, newest first.
- **"came back a solid black frame" / "Screen Recording".** The process invoking
  this script hasn't been granted Screen Recording. Grant it in System Settings →
  Privacy & Security → Screen Recording and re-run; there's no retrying past it.
- **"requires a Retina display" / a scale under 2x.** The display capturing this ran
  at native 1x. Run the harness on a Retina display — the failure is deliberate,
  to stop a mislabeled 0.5x asset from reaching `site/img`.
