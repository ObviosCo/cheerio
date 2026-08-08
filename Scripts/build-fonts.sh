#!/usr/bin/env bash
# Subsets the site's committed webfonts to the characters an English page
# actually uses, rewriting each woff2 in place.
#
# The upstream files cover Latin Extended, Greek and Cyrillic. The site is
# English. Subsetting to Latin plus punctuation cuts each file to roughly a
# fifth, with no visible difference.
#
# IBM Plex is deliberately NOT subsetted. Its OFL declares "Plex" a Reserved
# Font Name, and a subset is a Modified Version, which may not use that name
# without written permission (see site/fonts/IBMPlexSans-LICENSE.txt).
# Renaming the family internally would satisfy the licence but confuse
# everyone else; shipping IBM's files unmodified costs ~110 KB and zero
# lawyers. Literata and JetBrains Mono reserve no names, so they subset.
#
# This is NOT a build step. The site is correct without it and nothing in CI
# depends on it; it is a size pass worth running before shipping, and again
# whenever a font is replaced. Git keeps the originals.
#
#   ./Scripts/build-fonts.sh
#
# Needs fonttools with brotli:
#   pip install 'fonttools[woff]' brotli

set -euo pipefail

FONT_DIR="site/fonts"

if ! command -v pyftsubset >/dev/null 2>&1; then
    cat >&2 <<'EOF'
pyftsubset isn't on PATH.

    pip install 'fonttools[woff]' brotli

Then re-run. Nothing has been changed.
EOF
    exit 1
fi

if [ ! -d "$FONT_DIR" ]; then
    echo "Run this from the repository root — $FONT_DIR isn't here." >&2
    exit 1
fi

# Basic Latin, Latin-1 Supplement, the quotes and dashes real copy uses, and
# the arrows and box glyphs the docs lean on. Deliberately no Greek, no
# Cyrillic, no Latin Extended-B.
UNICODES="U+0000-00FF,U+0131,U+0152-0153,U+02BB-02BC,U+02C6,U+02DA,U+02DC,\
U+2000-206F,U+2074,U+20AC,U+2122,U+2191,U+2192,U+2193,U+2212,U+2215,U+FEFF,U+FFFD"

# Keep the OpenType features the type system actually relies on: kerning and
# standard ligatures everywhere, tabular figures and slashed zero for data,
# and the mono's coding ligatures.
FEATURES="kern,liga,clig,calt,tnum,zero,ss01,ss02,ss19,ss20"

subset_one() {
    local file="$1"
    local before after tmp

    if [ ! -f "$file" ]; then
        echo "  skipped $(basename "$file") — not found"
        return
    fi

    before=$(wc -c < "$file" | tr -d ' ')

    # Already subsetted files are much smaller than any upstream release.
    # Bailing here keeps a second run from quietly degrading the outlines.
    if [ "$before" -lt 45000 ]; then
        echo "  skipped $(basename "$file") — already subsetted ($before bytes)"
        return
    fi

    tmp="${file}.subset"
    pyftsubset "$file" \
        --output-file="$tmp" \
        --flavor=woff2 \
        --layout-features="$FEATURES" \
        --unicodes="$UNICODES" \
        --no-hinting \
        --desubroutinize \
        --drop-tables+=DSIG

    after=$(wc -c < "$tmp" | tr -d ' ')
    mv "$tmp" "$file"
    printf '  %-32s %7s -> %7s bytes  (-%d%%)\n' \
        "$(basename "$file")" "$before" "$after" \
        $(( (before - after) * 100 / before ))
}

echo "subsetting webfonts in $FONT_DIR to Latin"
total_before=$(cat "$FONT_DIR"/*.woff2 | wc -c | tr -d ' ')

# No IBM Plex here — Reserved Font Name, see the header.
for f in "$FONT_DIR"/Literata-Regular.woff2 \
         "$FONT_DIR"/JetBrainsMono-Regular.woff2; do
    subset_one "$f"
done

total_after=$(cat "$FONT_DIR"/*.woff2 | wc -c | tr -d ' ')
echo
printf 'total %s -> %s bytes\n' "$total_before" "$total_after"
echo "licences are unchanged and still apply — see $FONT_DIR/README.md"
