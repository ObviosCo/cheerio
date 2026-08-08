# Scripts/screenshots

Takes the app's picture. Same script for the website's imagery and for looking at a
change you can't read off a diff.

```sh
./Scripts/screenshots/capture.sh     # → Scripts/screenshots/out (gitignored)
./Scripts/screenshots/publish.sh     # → site/img, for the four the site uses
```

`capture.sh` builds the app if it doesn't find one (`--app <Cheerio.app>` to point at
your own), seeds a store full of invented meetings, and launches the app once per
shot. It takes two or three minutes and needs a logged-in graphical session — it is
photographing real windows, not rendering views offscreen.

## What it produces

| File | What's in it |
| --- | --- |
| `library` | The library with the richest meeting selected — notes, action items, follow-ups, speakers |
| `library-transcript` | A shorter meeting, so the attributed transcript is on screen under the notes |
| `onboarding-welcome` … `onboarding-finish` | All seven walkthrough steps, in order |
| `settings-participants`, `settings-updates`, `settings-callback` | Three of the five Settings tabs |

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
or XCUITest — and it's here because neither of those runs unattended:

- Synthetic input (`CGEventPost`, System Events, `cliclick`) needs the *automating*
  process to hold macOS Accessibility permission. Without it the events are dropped
  silently: the script reports a click and nothing happens.
- XCUITest needs developer mode enabled (`DevToolsSecurity -enable`), which is an
  admin-password prompt.

Both are one-time grants a person can make on their own machine, and neither is
something a fresh clone or a CI runner has. The launch arguments need nothing, and
they're also more repeatable — there's no click to land, no window that moved.

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
