#!/bin/bash
#
# The gate on the capture job: says which surfaces came out, and fails when any of
# them didn't.
#
#     ./Scripts/screenshots/ci/check-captures.sh --dir <pngs> \
#         --expected-from CheerioScreenshotTests/ScreenshotCaptureTests.swift \
#         [--capture-outcome success]
#
# Writes a markdown summary to stdout — the workflow tees it into
# `$GITHUB_STEP_SUMMARY` — and exits nonzero if the capture step reported anything but
# success, or if a surface is missing from `--dir`.
#
# **Why this exists.** The capture step is `continue-on-error`, so a surface that fails
# to photograph doesn't cost the reviewer the ones that worked. Without something after
# it, though, a run that photographed two screens out of nine reports the same green
# check as a run that photographed nine, and the whole point of the previews is that a
# reviewer can trust what they're looking at. Publication is unaffected: the publish
# workflow runs on completion either way, so a partial gallery still gets posted — this
# only makes the check status tell the truth about it.
#
# **The expected set is read out of the test file**, by name, rather than kept in a
# list beside it. `CheerioScreenshotTests` is where a surface is added, and a list that
# has to be updated in step with it is a list that will be wrong. The parse is narrow
# on purpose (`named: "<name>"`, which is how every shot is attached) and this refuses
# to run if it comes back with implausibly few, so a refactor that breaks it fails
# loudly here instead of quietly expecting nothing.

set -euo pipefail

DIR=""
EXPECTED_FROM=""
CAPTURE_OUTCOME="success"
# The floor under the parse. Nine surfaces are shot today; anything under this means
# the grep stopped matching the test file rather than that the suite shrank.
MIN_EXPECTED=5

while [ $# -gt 0 ]; do
    case "$1" in
        --dir) DIR="$2"; shift 2 ;;
        --expected-from) EXPECTED_FROM="$2"; shift 2 ;;
        --capture-outcome) CAPTURE_OUTCOME="$2"; shift 2 ;;
        --min-expected) MIN_EXPECTED="$2"; shift 2 ;;
        -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

[ -n "$DIR" ] || { echo "--dir is required" >&2; exit 2; }
[ -n "$EXPECTED_FROM" ] || { echo "--expected-from is required" >&2; exit 2; }
[ -f "$EXPECTED_FROM" ] || { echo "No test file at ${EXPECTED_FROM}" >&2; exit 1; }

expected=()
while IFS= read -r name; do
    [ -n "$name" ] || continue
    expected+=("$name")
done < <(
    grep -oE 'named: "[A-Za-z0-9][A-Za-z0-9._-]*"' "$EXPECTED_FROM" \
        | sed -E 's/^named: "(.*)"$/\1/' \
        | sort -u
)

if [ "${#expected[@]}" -lt "$MIN_EXPECTED" ]; then
    {
        echo "Read only ${#expected[@]} surface name(s) out of ${EXPECTED_FROM}, expected at least ${MIN_EXPECTED}."
        echo "The shots are matched by \`named: \"<name>\"\`; if that's no longer how the test file"
        echo "attaches them, this script is what has to change with it."
    } >&2
    exit 2
fi

missing=()
present=0
for name in "${expected[@]}"; do
    if [ -f "${DIR}/${name}.png" ]; then
        present=$((present + 1))
    else
        missing+=("$name")
    fi
done

echo "### Screen previews"
echo
printf -- '- Captured %d of the %d surfaces `%s` shoots.\n' \
    "$present" "${#expected[@]}" "$(basename "$EXPECTED_FROM" .swift)"

if [ "$CAPTURE_OUTCOME" != "success" ]; then
    printf -- '- The capture pass reported `%s`; whatever it did photograph is still attached to this run.\n' \
        "$CAPTURE_OUTCOME"
fi

# Reached when a step before the extraction failed, so this runs with nothing to look
# at. Said plainly, because "0 of 9" on its own reads like a capture problem.
if [ ! -d "$DIR" ]; then
    printf -- '- Nothing was extracted: there is no directory at `%s`, so the run failed before the captures were pulled out.\n' \
        "$DIR"
fi

if [ "${#missing[@]}" -gt 0 ]; then
    printf -- '- Missing:'
    for name in "${missing[@]}"; do
        printf ' `%s`' "$name"
    done
    printf '\n'
fi

if [ "$present" -gt 0 ]; then
    echo "- The pictures are attached to this run as the \`screens\` artifact; the *Publish screen previews*"
    echo "  workflow is what puts them on the pull request."
fi

if [ "${#missing[@]}" -gt 0 ] || [ "$CAPTURE_OUTCOME" != "success" ]; then
    echo
    echo "Failing the job: the previews are incomplete, and a green check would say otherwise."
    exit 1
fi
