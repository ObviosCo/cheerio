#!/bin/bash
#
# Pulls the captures out of an .xcresult and gets them ready to publish.
#
#     ./Scripts/screenshots/ci/extract-screenshots.sh --xcresult <path> --out <dir> \
#         [--preview-width 900]
#
# `CheerioScreenshotTests` attaches each shot with `lifetime = .keepAlways` and a
# name like `library.png`; xcresulttool exports every attachment under an opaque
# filename plus a manifest.json mapping it back to that name. This renames by the
# manifest, so what lands in `<dir>` is `library.png`, `settings-updates.png`, and so
# on — the same names the local harness writes, which is what makes the two
# comparable by eye.
#
# Alongside each capture it writes `<name>-preview.png`, width-capped so a PR comment
# embedding a dozen of them doesn't cost the reader ten megabytes. The full-size file
# stays for the link behind it. (Names are `-preview`, not `-1x`/`-2x`: a GitHub
# runner's display is 1x, so unlike the local harness there's no second scale to
# label — only a smaller copy.)
#
# Exits nonzero if there are no captures at all. A silent zero would let the workflow
# publish an empty gallery, which reads as "no visual change" rather than "the tests
# never got a picture".

set -euo pipefail

XCRESULT=""
OUT=""
PREVIEW_WIDTH=900

while [ $# -gt 0 ]; do
    case "$1" in
        --xcresult) XCRESULT="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --preview-width) PREVIEW_WIDTH="$2"; shift 2 ;;
        -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

[ -n "$XCRESULT" ] || { echo "--xcresult is required" >&2; exit 2; }
[ -n "$OUT" ] || { echo "--out is required" >&2; exit 2; }
[ -e "$XCRESULT" ] || { echo "No result bundle at ${XCRESULT}" >&2; exit 1; }

RAW="$(mktemp -d)"
trap 'rm -rf "$RAW"' EXIT

xcrun xcresulttool export attachments --path "$XCRESULT" --output-path "$RAW" >/dev/null

MANIFEST="${RAW}/manifest.json"
[ -f "$MANIFEST" ] || { echo "xcresulttool wrote no manifest.json to ${RAW}" >&2; exit 1; }

mkdir -p "$OUT"

# Oldest first, so a retried test's newer attachment overwrites the earlier one
# rather than the other way round.
count=0
while IFS=$'\t' read -r exported suggested; do
    [ -n "$exported" ] || continue
    case "$suggested" in
        *.png) ;;
        *) continue ;;
    esac
    # XCTest doesn't hand back the name the test set: it uniquifies it, so an
    # attachment named `library.png` arrives as `library_0_<UUID>.png`. Stripping
    # that back off is what makes the published filenames the stable, diffable ones
    # the comment and the site both expect — without it the branch fills with a new
    # set of names every run.
    name="$(printf '%s' "${suggested%.png}" | sed -E 's/_[0-9]+_[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$//')"
    # The name comes from a test file in this repo, but it ends up as a path here,
    # so it's reduced to characters that can only be a filename.
    name="$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '-')"
    cp "${RAW}/${exported}" "${OUT}/${name}.png"
    count=$((count + 1))
done < <(jq -r '
    [.[] | .attachments[]]
    | sort_by(.timestamp // 0)
    | .[]
    | [.exportedFileName, .suggestedHumanReadableName]
    | @tsv
' "$MANIFEST")

if [ "$count" = 0 ]; then
    echo "No .png attachments in ${XCRESULT}." >&2
    echo "The capture tests either skipped (no seeded demo store) or never reached a window." >&2
    exit 1
fi

# The width cap, applied only to the ones wider than it — sips would otherwise
# scale a narrow window *up* and publish a blurry copy of it.
for capture in "${OUT}"/*.png; do
    case "$capture" in *-preview.png) continue ;; esac
    name="$(basename "$capture" .png)"
    width="$(sips -g pixelWidth "$capture" | awk '/pixelWidth/ {print $2}')"
    cp "$capture" "${OUT}/${name}-preview.png"
    if [ "${width:-0}" -gt "$PREVIEW_WIDTH" ]; then
        sips --resampleWidth "$PREVIEW_WIDTH" "${OUT}/${name}-preview.png" >/dev/null
    fi
done

printf 'Extracted %d capture(s) to %s\n' "$count" "$OUT"
