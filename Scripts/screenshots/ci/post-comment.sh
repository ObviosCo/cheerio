#!/bin/bash
#
# Posts the screenshot comment, or edits the one that's already there.
#
#     ./Scripts/screenshots/ci/post-comment.sh --repo owner/name --pr 42 \
#         --body-file <file> [--marker '<!-- screenshot-previews -->']
#
# One comment per PR, forever: a run that finds a comment whose body starts with the
# marker edits that one instead of adding another. Otherwise a PR with a dozen pushes
# ends up with a dozen galleries and the review conversation is unreadable.
#
# `gh` needs a token with `pull-requests: write` in the environment (GH_TOKEN).

set -euo pipefail

REPO=""
PR=""
BODY_FILE=""
MARKER="<!-- screenshot-previews -->"

while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        --pr) PR="$2"; shift 2 ;;
        --body-file) BODY_FILE="$2"; shift 2 ;;
        --marker) MARKER="$2"; shift 2 ;;
        -h|--help) sed -n '2,13p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

[ -n "$REPO" ] || { echo "--repo is required" >&2; exit 2; }
[ -n "$PR" ] || { echo "--pr is required" >&2; exit 2; }
[ -n "$BODY_FILE" ] || { echo "--body-file is required" >&2; exit 2; }
[ -f "$BODY_FILE" ] || { echo "No body at ${BODY_FILE}" >&2; exit 1; }

# `--paginate` because the marker'd comment is the oldest one on a long-running PR,
# and the first page is the newest thirty.
existing="$(
    gh api --paginate "repos/${REPO}/issues/${PR}/comments" \
        --jq "map(select(.body | startswith(\"${MARKER}\"))) | .[0].id // empty" \
        | head -n 1
)"

if [ -n "$existing" ]; then
    gh api --method PATCH "repos/${REPO}/issues/comments/${existing}" \
        --field "body=@${BODY_FILE}" --silent
    echo "Updated comment ${existing} on ${REPO}#${PR}."
else
    gh api --method POST "repos/${REPO}/issues/${PR}/comments" \
        --field "body=@${BODY_FILE}" --silent
    echo "Posted a new screenshot comment on ${REPO}#${PR}."
fi
