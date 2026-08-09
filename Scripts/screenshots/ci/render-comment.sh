#!/bin/bash
#
# Writes the markdown for the PR's screenshot comment to stdout.
#
#     ./Scripts/screenshots/ci/render-comment.sh --dir <pngs> --raw-base <url> \
#         --sha <sha> [--marker '<!-- screenshot-previews -->'] [--run-url <url>]
#
# `--raw-base` is the raw.githubusercontent prefix the captures were published under,
# e.g. https://raw.githubusercontent.com/ObviosCo/cheerio/screenshots/pr-42/<sha>.
#
# Each surface is embedded at preview width with the full-size capture behind the
# link, one `<details>` per surface after the first two so a dozen screens don't push
# the review conversation off the page. The marker on the first line is how
# post-comment.sh finds this comment again to update it, so it has to stay first and
# stay exact.

set -euo pipefail

DIR=""
RAW_BASE=""
SHA=""
MARKER="<!-- screenshot-previews -->"
RUN_URL=""

while [ $# -gt 0 ]; do
    case "$1" in
        --dir) DIR="$2"; shift 2 ;;
        --raw-base) RAW_BASE="$2"; shift 2 ;;
        --sha) SHA="$2"; shift 2 ;;
        --marker) MARKER="$2"; shift 2 ;;
        --run-url) RUN_URL="$2"; shift 2 ;;
        -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

[ -n "$DIR" ] || { echo "--dir is required" >&2; exit 2; }
[ -n "$RAW_BASE" ] || { echo "--raw-base is required" >&2; exit 2; }
[ -d "$DIR" ] || { echo "No directory at ${DIR}" >&2; exit 1; }

# Alphabetical, which puts `library` before `library-transcript` before the settings
# tabs — the order someone reads them in, and stable between runs.
captures=()
while IFS= read -r file; do
    captures+=("$file")
done < <(find "$DIR" -type f -name '*.png' ! -name '*-preview.png' | sort)

[ "${#captures[@]}" -gt 0 ] || { echo "No captures in ${DIR}." >&2; exit 1; }

# A heading a human would write, from a filename a script did:
# `settings-updates` → `Settings Updates`.
title() {
    printf '%s' "$1" | tr '-' ' ' | awk '{
        for (i = 1; i <= NF; i++) { $i = toupper(substr($i, 1, 1)) substr($i, 2) }
        print
    }'
}

printf '%s\n' "$MARKER"
printf '## Screens\n\n'
# `<sha>` is the head commit, but what CI checks out for a pull request is that commit
# merged into the base — which is the more useful thing to have photographed, and
# worth saying rather than implying.
printf 'Taken from `%s` merged into the base, against a store of invented meetings.\n' "${SHA:0:7}"
printf 'Every image links to its full-size copy.\n\n'

index=0
for capture in "${captures[@]}"; do
    name="$(basename "$capture" .png)"
    heading="$(title "$name")"
    body="[![${heading}](${RAW_BASE}/${name}-preview.png)](${RAW_BASE}/${name}.png)"
    # The first two — the library, which is the app — stay open; the rest fold away.
    if [ "$index" -lt 2 ]; then
        printf '**%s**\n\n%s\n\n' "$heading" "$body"
    else
        printf '<details><summary>%s</summary>\n\n%s\n\n</details>\n\n' "$heading" "$body"
    fi
    index=$((index + 1))
done

printf -- '---\n\n'
printf 'These are captured by `CheerioScreenshotTests` on the runner, not by hand'
if [ -n "$RUN_URL" ]; then
    printf ' — [run](%s)' "$RUN_URL"
fi
printf '. They live on the disposable `screenshots` branch; see `Scripts/screenshots/README.md`.\n'
