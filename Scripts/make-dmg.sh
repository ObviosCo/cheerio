#!/usr/bin/env bash
# Builds the download disk image: Cheerio.app on the left, an /Applications
# symlink on the right, an arrow between them, over generated navy art.
#
# Why a DMG exists at all, when the zip already works: Safari auto-extracts a
# downloaded zip, people double-click Cheerio.app straight out of ~/Downloads,
# and macOS runs it under app translocation — a randomised, read-only mount.
# Sparkle cannot update an app running from there, so an early adopter is
# silently stranded on the version they first downloaded. A DMG's one gesture,
# drag-to-Applications, puts the app somewhere it can update itself. The zip
# stays: it is what the appcast's enclosure points at, and Sparkle installs
# over the app's real location where translocation never applies.
#
# ---------------------------------------------------------------------------
# Why dmgbuild and not create-dmg
#
# Every visual property of a DMG window — icon coordinates, window size,
# background image — lives in a .DS_Store on the volume. There are three ways
# to write one:
#
#   1. create-dmg (the shell one, create-dmg/create-dmg, MIT). Drives Finder
#      over AppleScript. Its own README ships --skip-jenkins to "skip
#      Finder-prettifying AppleScript, useful in Sandbox and non-GUI
#      environments", an --applescript-sleep-duration knob to "workaround
#      occasional issues", and documents intermittent "Can't get disk" (-1728)
#      failures. In CI that is a layout that sometimes silently doesn't happen,
#      on a runner with no real GUI session. Ruled out; issue #55 asks for no
#      GUI-automation hacks.
#   2. A .DS_Store built once by hand and committed. Zero build-time
#      dependencies, but it does not remove the tool — it only moves it to an
#      un-repeatable manual step, and leaves an opaque binary in the tree that
#      no reviewer can read and nobody can regenerate without Finder. Against
#      this repo's "generated, not drawn" convention.
#   3. dmgbuild (MIT, pinned in Scripts/dmg-requirements.txt). Writes the
#      .DS_Store directly with the ds_store and mac_alias modules — no
#      AppleScript, no Finder, no GUI session — and takes the layout from a
#      readable settings file (Scripts/dmg-settings.py). Chosen.
#
# dmgbuild and its two dependencies are pinned to exact versions with hashes.
# They are build-time only, like XcodeGen: nothing from them is redistributed
# inside the app, so THIRD-PARTY-NOTICES.md does not cover them.
#
# Layout is not trusted either way. Writing a .DS_Store fails quietly — icons
# fall into a default grid, the background reverts to white, and the image
# still mounts and still works — so this script mounts the finished image and
# runs Scripts/verify-dmg.py against it before calling it built.
#
# Signing, notarizing and stapling are *not* done here: they need secrets and
# belong to .github/workflows/release.yml, which does them to the file this
# script produces.
#
# Usage:
#   Scripts/make-dmg.sh --app <path/to/Cheerio.app> --output <Cheerio-1.2.3.dmg>
#                       [--work-dir build/dmg] [--volume-name Cheerio]
#
# Requires dmgbuild on PATH:
#   python3 -m venv .dmg-venv
#   ./.dmg-venv/bin/pip install --require-hashes -r Scripts/dmg-requirements.txt
#   PATH="$PWD/.dmg-venv/bin:$PATH" Scripts/make-dmg.sh --app ... --output ...

set -euo pipefail

app=""
output=""
work_dir="build/dmg"
volume_name="Cheerio"

while [ $# -gt 0 ]; do
  case "$1" in
    --app) app="${2:?--app needs a path}"; shift 2 ;;
    --output) output="${2:?--output needs a path}"; shift 2 ;;
    --work-dir) work_dir="${2:?--work-dir needs a path}"; shift 2 ;;
    --volume-name) volume_name="${2:?--volume-name needs a name}"; shift 2 ;;
    -h|--help) sed -n '2,60p' "$0"; exit 0 ;;
    *) echo "make-dmg.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$app" ] && [ -n "$output" ] || {
  echo "make-dmg.sh: --app and --output are both required" >&2
  exit 2
}
[ -d "$app" ] || { echo "make-dmg.sh: no app bundle at $app" >&2; exit 1; }

script_dir="$(cd "$(dirname "$0")" && pwd)"
settings="$script_dir/dmg-settings.py"
renderer="$script_dir/render-dmg-background.swift"
verifier="$script_dir/verify-dmg.py"
# The icon-well/arrow geometry lives here once, not twice: the renderer and
# dmg-settings.py both read it, so a missing file means neither would agree
# on a layout — fail before either gets the chance to guess.
geometry="$script_dir/dmg-geometry.json"
for f in "$settings" "$renderer" "$verifier" "$geometry"; do
  [ -f "$f" ] || { echo "make-dmg.sh: missing $f" >&2; exit 1; }
done

command -v dmgbuild > /dev/null || {
  echo "make-dmg.sh: dmgbuild is not on PATH. Install it with:" >&2
  echo "  python3 -m venv .dmg-venv" >&2
  echo "  ./.dmg-venv/bin/pip install --require-hashes -r Scripts/dmg-requirements.txt" >&2
  echo "  export PATH=\"\$PWD/.dmg-venv/bin:\$PATH\"" >&2
  exit 1
}
# verify-dmg.py imports ds_store and mac_alias, which came in as dmgbuild's
# dependencies — so use the interpreter from wherever dmgbuild was installed
# rather than whichever python3 happens to be first on PATH.
python_bin="$(dirname "$(command -v dmgbuild)")/python3"
[ -x "$python_bin" ] || python_bin="python3"

# Absolute, because dmgbuild is invoked from here but resolves nothing for us.
output_dir="$(cd "$(dirname "$output")" && pwd)"
output="$output_dir/$(basename "$output")"

rm -rf "$work_dir"
mkdir -p "$work_dir"
work_dir="$(cd "$work_dir" && pwd)"

# ---- Background art ------------------------------------------------------
# Generated, not committed: it is derived from the same coordinates the layout
# uses, and nothing but the DMG consumes it.
echo "==> Rendering background art"
swift "$renderer" "$work_dir"

# A multi-representation TIFF is how one background file serves both a 1x and a
# Retina display: Finder picks the matching representation. Two separate PNGs
# cannot do that — the 1x would simply be scaled up and go soft.
echo "==> Combining 1x and 2x into a multi-resolution TIFF"
tiffutil -cathidpicheck \
  "$work_dir/background.png" "$work_dir/background@2x.png" \
  -out "$work_dir/background.tiff"

# ---- Build ---------------------------------------------------------------
echo "==> Building $(basename "$output")"
rm -f "$output"
dmgbuild \
  -s "$settings" \
  -D app="$(cd "$(dirname "$app")" && pwd)/$(basename "$app")" \
  -D background="$work_dir/background.tiff" \
  -D geometry="$geometry" \
  "$volume_name" \
  "$output"

# hdiutil's own integrity check on the finished image, before anyone downloads it.
echo "==> Verifying image integrity"
hdiutil verify "$output"

# ---- Verify the layout ---------------------------------------------------
# -nobrowse so a mount on a developer's machine doesn't open a Finder window,
# and an explicit mountpoint so nothing depends on /Volumes being free — a
# leftover /Volumes/Cheerio would otherwise silently become "Cheerio 1".
mount_point="$work_dir/mnt"
mkdir -p "$mount_point"
detach() {
  if mount | grep -q " on $mount_point "; then
    # A mount can be briefly busy after being read; a couple of tries is
    # enough, and -force on the last so a stuck mount can't fail the build.
    hdiutil detach "$mount_point" > /dev/null 2>&1 \
      || { sleep 2; hdiutil detach "$mount_point" -force > /dev/null 2>&1 || true; }
  fi
}
trap detach EXIT

echo "==> Mounting to check the layout"
hdiutil attach "$output" -readonly -nobrowse -noautoopen -mountpoint "$mount_point" > /dev/null

"$python_bin" "$verifier" "$mount_point" \
  --settings "$settings" \
  --app-name "$(basename "$app")"

detach
trap - EXIT

echo
echo "Built $output ($(du -h "$output" | cut -f1))"
