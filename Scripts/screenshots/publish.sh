#!/bin/bash
#
# Copies the captures the website uses out of out/ and into site/img/, shrinking
# them on the way.
#
#     ./Scripts/screenshots/capture.sh && ./Scripts/screenshots/publish.sh
#
# Only the four the page actually references are published; the rest of what
# capture.sh produces is for looking at in a pull request. If you add a figure to
# site/index.html, add its name here.
#
# The shrinking is a 256-colour palette. These are flat, light UI screenshots —
# large areas of one colour and antialiased text — so quantizing is visually
# lossless on them and cuts the files by about 75%, which is the difference between
# a home page that costs 2 MB and one that costs 600 KB. It needs ImageMagick
# (`brew install imagemagick`); without it the files are copied through unchanged
# and the page still works, just heavier.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
OUT="${HERE}/out"
IMG="${ROOT}/site/img"

# The figures site/index.html references, by capture name.
PUBLISHED=(library library-transcript onboarding-voice settings-callback)

if command -v magick >/dev/null 2>&1; then
    optimize() { magick "$1" -strip -colors 256 "PNG8:$2"; }
else
    printf '\033[33m!\033[0m ImageMagick not found — copying without shrinking.\n'
    optimize() { cp "$1" "$2"; }
fi

for name in "${PUBLISHED[@]}"; do
    for variant in "" "-2x"; do
        source="${OUT}/${name}${variant}.png"
        [ -f "$source" ] || { echo "missing ${source} — run capture.sh first" >&2; exit 1; }
        optimize "$source" "${IMG}/${name}${variant}.png"
        printf '   %-30s %s\n' "${name}${variant}.png" \
            "$(du -h "${IMG}/${name}${variant}.png" | cut -f1)"
    done
done

printf '\n\033[32m✓\033[0m %s\n\n' "site/img is $(du -sh "$IMG" | cut -f1) in total"
