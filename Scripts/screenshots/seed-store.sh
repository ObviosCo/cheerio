#!/bin/bash
#
# Writes the demo store both halves of the screenshot harness photograph.
#
#     ./Scripts/screenshots/seed-store.sh [--home <dir>] [--bundle-id <id>] [--skip-enrollment]
#
# `<dir>` is a scratch *home* directory — the store lands in
# `<dir>/Library/Application Support/<bundle-id>`, which is where the app looks
# once it's launched with `CFFIXED_USER_HOME` pointed at `<dir>`. The container
# path is printed on stdout, so a caller that wants it can capture it.
#
# `--skip-enrollment` writes the same meetings with nobody enrolled — the
# "recorded without enrolling" case issue #125's empty-state prompt has to keep
# confronting rather than assume away. Used for a second, separately-seeded home;
# it isn't a flag on the one everything else photographs, since that store is also
# what the enrolled-roster shots (Settings → Participants, the transcript's named
# speakers) depend on.
#
# Extracted from capture.sh so the CI capture pass (CheerioScreenshotTests, run by
# .github/workflows/screenshots.yml) seeds from the same code the local script does.
# The two halves differ only in how they take the picture; the data in it is this.
#
# Everything the store holds is invented — see
# SeedDemoStore/Sources/SeedDemoStore/main.swift, and keep it that way: these
# captures get published.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The default is a fixed path rather than a mktemp one because
# CheerioScreenshotTests falls back to this same literal when
# CHEERIO_SCREENSHOT_HOME isn't set. Change one, change the other.
HOME_DIR="/tmp/cheerio-screenshots-home"
BUNDLE_ID="co.obvios.cheerio.mac"
SEED_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --home) HOME_DIR="$2"; shift 2 ;;
        --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
        --skip-enrollment) SEED_ARGS+=("--skip-enrollment"); shift ;;
        -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

CONTAINER="${HOME_DIR}/Library/Application Support/${BUNDLE_ID}"

# A store left over from an earlier run would be opened and added to rather than
# replaced, so the captures would slowly fill with duplicates. Only ever the
# container itself, never the home around it.
rm -rf "$CONTAINER"
mkdir -p "$CONTAINER"

# Built and run from source so the store always matches the schema the app is
# about to open. Progress goes to /dev/null and diagnostics to stderr, leaving
# stdout holding one line: the container path.
swift build --package-path "${HERE}/SeedDemoStore" >/dev/null
"$(swift build --package-path "${HERE}/SeedDemoStore" --show-bin-path)/SeedDemoStore" \
    --container "$CONTAINER" "${SEED_ARGS[@]+"${SEED_ARGS[@]}"}" >/dev/null

printf '%s\n' "$CONTAINER"
