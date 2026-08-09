#!/bin/bash
#
# Photographs the app against a seeded demo store.
#
#     ./Scripts/screenshots/capture.sh [--app <Cheerio.app>] [--out <dir>] [--skip-build]
#
# Writes a fixed set of PNGs to Scripts/screenshots/out (gitignored), each at the
# display's native scale as `<name>-2x.png` plus a half-size `<name>.png`, which is
# the 1x/2x pair site/index.html's `srcset` expects.
#
# Rebuilds Cheerio (Debug) by default, so a capture always comes off the code that's
# actually checked out rather than whatever last happened to be sitting in build/.
# Pass --skip-build to reuse an existing build/screenshots app as-is when iterating
# on the harness itself and the app hasn't changed; pass --app to point at a build of
# your own instead, which is used as-is and never rebuilt.
#
# How it stays away from your real data:
#
# - The app is launched with `CFFIXED_USER_HOME` pointed at a scratch directory,
#   which is what moves `~/Library/Application Support` — and with it the SwiftData
#   store — into that directory. `HOME` alone does *not*: Foundation resolves the
#   home directory through CoreFoundation, which reads `CFFIXED_USER_HOME` and
#   ignores `HOME`. (It's set as well, for anything that shells out.)
# - Preferences are the exception: they go through cfprefsd, which resolves the
#   domain by uid and so writes to your real preferences whatever the environment
#   says. This script exports them before it starts and imports them back at the
#   end, and everything it needs the app to *read* is passed as a launch argument —
#   the argument domain, which is read-only and dies with the process.
# - Windows are found by the launched process's own pid, so a real Cheerio running
#   at the same time is never captured, and only the pid this script started is ever
#   killed.
#
# Why the app is driven by launch arguments rather than by a script clicking it:
# synthetic clicks need macOS Accessibility permission granted to the automating
# process, which a fresh machine hasn't got. See `ScreenshotMode` in the app target
# for the four hooks, and README.md here for what that trades away. The CI capture
# pass (CheerioScreenshotTests) uses the same hooks for the same reason — it could
# click, being a UI test, and gets there in one launch instead.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
OUT="${HERE}/out"
APP=""
SKIP_BUILD=0

while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        -h|--help) sed -n '2,38p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

step() { printf '\033[34m→\033[0m %s\n' "$1"; }
fail() { printf '\n\033[31m✗\033[0m %s\n\n' "$1" >&2; exit 1; }

# 1. The app. Built into build/ (gitignored) unless one was passed in. Rebuilt on
#    every run by default — otherwise a stale build from a previous run keeps getting
#    photographed after the code has moved on, silently. --skip-build opts back into
#    the old "build once, iterate on the harness" behaviour; --app bypasses both.
if [ -z "$APP" ]; then
    APP="${ROOT}/build/screenshots/Build/Products/Debug/Cheerio.app"
    if [ "$SKIP_BUILD" = 1 ]; then
        [ -d "$APP" ] || fail "No app at ${APP} — drop --skip-build to build one, or pass --app."
    else
        [ -d "${ROOT}/Cheerio.xcodeproj" ] || fail "No Cheerio.xcodeproj — run ./Scripts/bootstrap.sh first."
        step "Building Cheerio (Debug)"
        xcodebuild -project "${ROOT}/Cheerio.xcodeproj" -scheme Cheerio -configuration Debug \
            -derivedDataPath "${ROOT}/build/screenshots" build >/dev/null \
            || fail "Build failed. Run it yourself to see why, or pass --app."
    fi
fi
[ -d "$APP" ] || fail "No app at ${APP}"
BUNDLE_ID="$(defaults read "${APP}/Contents/Info" CFBundleIdentifier)"

# 2. Scratch container, and a copy of your real preferences to put back afterwards.
SCRATCH="$(mktemp -d /tmp/cheerio-screenshots.XXXXXX)"
# BSD mktemp only substitutes trailing X's — a template like `prefs.XXXXXX.plist`
# leaves the X's untouched (same literal name every run), and a second run then dies
# under set -e when mkstemp refuses to recreate it. X's stay trailing; the extension
# — which nothing here actually depends on, `defaults export` doesn't care — is added
# by renaming afterwards.
PREFS_BACKUP="$(mktemp /tmp/cheerio-prefs.XXXXXX)"
mv "$PREFS_BACKUP" "${PREFS_BACKUP}.plist"
PREFS_BACKUP="${PREFS_BACKUP}.plist"
HAD_PREFS=0
if defaults read "$BUNDLE_ID" >/dev/null 2>&1; then
    defaults export "$BUNDLE_ID" "$PREFS_BACKUP"
    HAD_PREFS=1
fi
APP_PID=""

cleanup() {
    [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null || true
    # Only ever put back what was there. Deleting the domain in the other case looks
    # tidier and isn't worth it: one flaky read at the start of the run would turn
    # into someone's preferences being wiped at the end of it. A few keys the app
    # wrote itself are a much smaller mess.
    if [ "$HAD_PREFS" = 1 ]; then
        defaults import "$BUNDLE_ID" "$PREFS_BACKUP" 2>/dev/null || true
    fi
    rm -f "$PREFS_BACKUP"
    rm -rf "$SCRATCH"
}
trap cleanup EXIT

mkdir -p "$OUT"

# 3. Demo data. seed-store.sh builds and runs the seeder from source, so the store
#    always matches the schema the app is about to open — and so the CI capture pass
#    photographs the same invented meetings this one does.
step "Seeding the demo store"
"${HERE}/seed-store.sh" --home "$SCRATCH" --bundle-id "$BUNDLE_ID" >/dev/null

step "Compiling the window capturer"
swiftc -O -o "${SCRATCH}/capture-window" "${HERE}/capture-window.swift"

# 4. One launch per shot: the state each one needs is set by launch arguments, so a
#    fresh process is both the simplest way to get there and the most repeatable.
launch() {
    env CFFIXED_USER_HOME="$SCRATCH" HOME="$SCRATCH" \
        "${APP}/Contents/MacOS/Cheerio" \
        -SUEnableAutomaticChecks NO -SUAutomaticallyUpdate NO \
        "$@" >/dev/null 2>&1 &
    APP_PID=$!
}

quit() {
    [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
    APP_PID=""
    # Give the window server a moment to forget the windows before the next launch.
    sleep 1
}

# shot <name> <capture-flags...> -- <app-arguments...>
shot() {
    local name="$1"; shift
    local flags=()
    while [ "${1:-}" != "--" ]; do flags+=("$1"); shift; done
    shift
    launch "$@"
    # The `+` form so an empty array doesn't trip `set -u` on the bash macOS ships.
    "${SCRATCH}/capture-window" --pid "$APP_PID" --out "${OUT}/${name}-2x.png" \
        ${flags[@]+"${flags[@]}"} >/dev/null
    quit
    # The 1x half of the srcset. Captures come off a Retina display at 2x, so this
    # is an exact halving rather than a resample to a target size.
    local width
    width="$(sips -g pixelWidth "${OUT}/${name}-2x.png" | awk '/pixelWidth/ {print $2}')"
    cp "${OUT}/${name}-2x.png" "${OUT}/${name}.png"
    sips --resampleWidth "$((width / 2))" "${OUT}/${name}.png" >/dev/null
    printf '   %s\n' "${name}.png / ${name}-2x.png"
}

LIBRARY_ARGS=(-onboardingHasCompleted YES -screenshotWindowSize 1440x900)

step "Library"
shot library -- "${LIBRARY_ARGS[@]}" -screenshotSelectMeeting 1
shot library-transcript -- "${LIBRARY_ARGS[@]}" -screenshotSelectMeeting 2 -screenshotExpandTranscript YES

step "Onboarding"
# `-screenshotOnboardingStep` both opens the walkthrough window and decides which
# step it opens on, so onboarding is marked complete here — the walkthrough is
# opened deliberately rather than by being a first run. The library window is
# behind it; --title-contains keeps the capture on the walkthrough.
#
# The three permission steps are photographed in their explain state. Nothing here
# presses the button that asks macOS for anything, and nothing in this script can
# start a recording.
onboarding_steps=(welcome microphone system-audio calendar voice teammates finish)
for index in "${!onboarding_steps[@]}"; do
    shot "onboarding-${onboarding_steps[$index]}" --title-contains Welcome -- \
        -onboardingHasCompleted YES -screenshotOnboardingStep "$index"
done

step "Settings"
# Tab order is the order of `SettingsView`'s TabView: General, Privacy,
# Participants, Updates, Callback, Agents. SwiftUI stores the selection in this
# default, so passing it as a launch argument opens the tab without a click. The
# Settings window takes the selected tab's name as its title, which is also how
# it's told apart from the library window behind it.
#
# Agents (index 5) isn't shot here yet — it has nothing to show but a helper path
# and a copy button, and it joins this gallery once capture runs on CI (issue #61).
settings_shot() { # <name> <tab index> <window title> [extra app arguments...]
    local name="$1" tab="$2" title="$3"; shift 3
    shot "$name" --title-contains "$title" -- "${LIBRARY_ARGS[@]}" \
        -screenshotOpenSettings YES -com_apple_SwiftUI_Settings_selectedTabIndex "$tab" "$@"
}
settings_shot settings-participants 2 Participants
settings_shot settings-updates 3 Updates
settings_shot settings-callback 4 Callback \
    -transcriptCallbackCommand 'claude -p "Turn my action items into tasks"'

printf '\n\033[32m✓\033[0m %s\n\n' "Wrote $(ls -1 "${OUT}"/*.png | wc -l | tr -d ' ') files to ${OUT}"
