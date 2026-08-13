#!/bin/bash
#
# Checks the artifact a capture run handed over, and works out what — if anything —
# this run is allowed to publish.
#
#     ./Scripts/screenshots/ci/verify-handoff.sh --dir <downloaded> --staging <clean> \
#         --repo owner/name --event pull_request --head-sha <sha> --head-repo owner/name \
#         [--pr-candidates-json '[{"number":42}]'] [--max-bytes N] [--max-files N]
#
# stdout is `key=value` lines for `$GITHUB_OUTPUT` — `publish`, `comment`, `pr`,
# `prefix`, `reason` — and everything a human reads goes to stderr. Exits nonzero only
# when the artifact is malformed or the identity checks contradict each other;
# "this run doesn't publish" is `publish=false` and a zero exit, because a fork's pull
# request taking that path is ordinary.
#
# **This is the seam in the trust boundary.** The capture workflow runs on
# `pull_request` and so builds this artifact out of unreviewed code; this script runs
# in `screenshots-publish.yml`, from the base branch, holding a write token. Everything
# below assumes a pull request wrote the input on purpose:
#
# - the downloaded tree may contain nothing but flat files — no directories, no
#   symlinks — named `<something>.png` plus the one `metadata.json`, each with a real
#   PNG header, under a count and a byte budget;
# - each full-size capture must have its `-preview` sibling and vice versa, because
#   the comment embeds one and links the other;
# - **only what passes is copied into `--staging`**, and that clean directory is what
#   `publish-branch.sh` and `render-comment.sh` are pointed at. They never read the
#   download.
#
# And the identity of the run — which pull request, which commit — comes from the
# `workflow_run` payload, never from the artifact. `metadata.json` is allowed to agree
# with the payload and nothing else. Where the payload doesn't carry a PR number (it
# can arrive with an empty `pull_requests`), the candidates come from GitHub's own
# "which pull requests contain this commit" endpoint, and the artifact's number is only
# ever used to *choose among* those. It can't introduce one.

set -euo pipefail

DIR=""
STAGING=""
REPO=""
EVENT=""
HEAD_SHA=""
HEAD_REPO=""
PR_CANDIDATES_JSON="[]"
# The same budget publish-branch.sh enforces before it commits, checked here first so
# an oversized artifact is a verification failure rather than a publishing one.
MAX_BYTES=$((10 * 1024 * 1024))
# Nine surfaces today, each with a preview: eighteen files. The cap is loose enough
# not to bind on a few more surfaces and tight enough to stop a directory of junk.
MAX_FILES=64

while [ $# -gt 0 ]; do
    case "$1" in
        --dir) DIR="$2"; shift 2 ;;
        --staging) STAGING="$2"; shift 2 ;;
        --repo) REPO="$2"; shift 2 ;;
        --event) EVENT="$2"; shift 2 ;;
        --head-sha) HEAD_SHA="$2"; shift 2 ;;
        --head-repo) HEAD_REPO="$2"; shift 2 ;;
        --pr-candidates-json) PR_CANDIDATES_JSON="$2"; shift 2 ;;
        --max-bytes) MAX_BYTES="$2"; shift 2 ;;
        --max-files) MAX_FILES="$2"; shift 2 ;;
        -h|--help) sed -n '2,38p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

for required in DIR STAGING REPO EVENT HEAD_SHA; do
    eval "value=\${${required}}"
    [ -n "$value" ] || { echo "--$(printf '%s' "$required" | tr 'A-Z_' 'a-z-') is required" >&2; exit 2; }
done
[ -d "$DIR" ] || { echo "No directory at ${DIR}" >&2; exit 1; }

note() { printf '%s\n' "$*" >&2; }
fail() { printf '%s\n' "$*" >&2; exit 1; }

# The SHA ends up in a path on the screenshots branch, so it's checked for shape even
# though it came from the payload. Cheap, and it means no caller has to trust the
# other's escaping.
case "$HEAD_SHA" in
    *[!0-9a-f]* | "") fail "head SHA is not a hex object name: ${HEAD_SHA}" ;;
esac
[ "${#HEAD_SHA}" = 40 ] || fail "head SHA is not 40 characters: ${HEAD_SHA}"

# --- The artifact ------------------------------------------------------------------

# Anything that isn't a plain file is refused outright rather than skipped: a symlink
# or a nested directory in here means the upload didn't come from the step that's
# supposed to have made it, and that's worth stopping for.
strays="$(find "$DIR" -mindepth 1 ! -type f -print)"
[ -z "$strays" ] || fail "The artifact contains something that isn't a plain file:
${strays}"

METADATA="${DIR}/metadata.json"
[ -f "$METADATA" ] || fail "The artifact has no metadata.json."

rm -rf "${STAGING:?}"
mkdir -p "$STAGING"

files=0
bytes=0
# Enumerated with `find` rather than `"$DIR"/*`, because a glob doesn't match a name
# that starts with a dot — and something the checks below can't see is something they
# can't refuse. Everything here is a plain file: the sweep above stopped for anything
# that wasn't.
while IFS= read -r path; do
    [ -n "$path" ] || continue
    name="$(basename "$path")"
    if [ "$name" = "metadata.json" ]; then
        continue
    fi

    # A filename that can only be a filename: no leading dash or dot, no separators,
    # nothing but the characters the extractor already reduces its names to.
    case "$name" in
        *.png) ;;
        *) fail "The artifact contains a non-PNG file: ${name}" ;;
    esac
    if ! printf '%s' "$name" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*\.png$'; then
        fail "Refusing a capture whose name isn't a plain filename: ${name}"
    fi

    # The extension is a claim; the first eight bytes are the file.
    magic="$(head -c 8 "$path" | od -An -tx1 | tr -d ' \n')"
    [ "$magic" = "89504e470d0a1a0a" ] || fail "${name} isn't a PNG (header: ${magic})."

    size="$(wc -c < "$path" | tr -d ' ')"
    files=$((files + 1))
    bytes=$((bytes + size))
    cp "$path" "${STAGING}/${name}"
done < <(find "$DIR" -mindepth 1 -maxdepth 1 -print)

[ "$files" -gt 0 ] || fail "The artifact has no captures in it."
[ "$files" -le "$MAX_FILES" ] || fail "The artifact has ${files} files, over the ${MAX_FILES}-file cap."
[ "$bytes" -le "$MAX_BYTES" ] || fail "The captures total ${bytes} bytes, over the ${MAX_BYTES}-byte budget."

# The comment embeds `<name>-preview.png` and links `<name>.png`, so a set that's
# missing either half publishes a broken image.
for path in "$STAGING"/*.png; do
    name="$(basename "$path" .png)"
    case "$name" in
        *-preview)
            full="${name%-preview}"
            [ -f "${STAGING}/${full}.png" ] || fail "${name}.png has no full-size ${full}.png beside it."
            ;;
        *)
            [ -f "${STAGING}/${name}-preview.png" ] || fail "${name}.png has no ${name}-preview.png beside it."
            ;;
    esac
done

note "Verified ${files} file(s), ${bytes} bytes."

# --- Who this run belongs to -------------------------------------------------------

META_EVENT="$(jq -r '.event // ""' "$METADATA")"
META_SHA="$(jq -r '.head_sha // ""' "$METADATA")"
META_REPO="$(jq -r '.head_repo // ""' "$METADATA")"
META_PR="$(jq -r '.pr // ""' "$METADATA")"

[ "$META_EVENT" = "$EVENT" ] || fail "metadata.json says the event was '${META_EVENT}'; the run says '${EVENT}'."
[ "$META_SHA" = "$HEAD_SHA" ] || fail "metadata.json says the head was '${META_SHA}'; the run says '${HEAD_SHA}'."
if [ -n "$HEAD_REPO" ] && [ "$META_REPO" != "$HEAD_REPO" ]; then
    fail "metadata.json says the head repo was '${META_REPO}'; the run says '${HEAD_REPO}'."
fi

emit() {
    printf 'publish=%s\n' "$1"
    printf 'comment=%s\n' "$2"
    printf 'pr=%s\n' "$3"
    printf 'prefix=%s\n' "$4"
    printf 'reason=%s\n' "$5"
}

# A dispatched run is how previews are asked for now that captures no longer fire on
# every pull request. Dispatching against a pull request's branch should still comment
# there, so ask GitHub which pull requests that head belongs to — the same question the
# `pull_request` path falls back on, and the same answer, from GitHub rather than from
# the artifact. Exactly one match is the ordinary case and gets the pull request's
# prefix and a comment. None (a dispatch from `main`, say) or several (an ambiguous
# head) publish under `manual/` with nothing to comment on, because guessing which
# pull request a reader meant is worse than making them open the branch.
if [ "$EVENT" = "workflow_dispatch" ]; then
    dispatch_prs="$(
        gh api "repos/${REPO}/commits/${HEAD_SHA}/pulls" \
            --jq ".[] | select(.head.sha == \"${HEAD_SHA}\") | .number" 2>/dev/null || true
    )"
    dispatch_count="$(printf '%s' "$dispatch_prs" | grep -c '[0-9]' || true)"
    if [ "$dispatch_count" = "1" ]; then
        dispatch_pr="$(printf '%s' "$dispatch_prs" | tr -d '[:space:]')"
        note "A requested run on the head of PR #${dispatch_pr}: publishing and commenting there."
        emit true true "$dispatch_pr" "pr-${dispatch_pr}/${HEAD_SHA}" ""
        exit 0
    fi
    note "A manual run: publishing under manual/${HEAD_SHA}, with no single pull request to comment on."
    emit true false "" "manual/${HEAD_SHA}" ""
    exit 0
fi

if [ "$EVENT" != "pull_request" ]; then
    note "Nothing to do for a '${EVENT}' run."
    emit false false "" "" "the capture run was triggered by ${EVENT}"
    exit 0
fi

# A fork's captures were rendered by code nobody has reviewed. The token would allow
# publishing them now — `workflow_run` runs in the base repo either way — and that is
# exactly why the decision has to be made deliberately rather than inherited from
# whatever the trigger happened to permit.
if [ "$HEAD_REPO" != "$REPO" ]; then
    note "The head is ${HEAD_REPO}, not ${REPO}: a fork's captures stay an artifact."
    emit false false "" "" "the pull request is from a fork, whose captures aren't published"
    exit 0
fi

# GitHub's account of which pull requests the triggering run belongs to. The artifact
# has no say in what goes in this list.
candidates="$(printf '%s' "$PR_CANDIDATES_JSON" | jq -r 'if type == "array" then .[].number else empty end')"
if [ -z "$candidates" ]; then
    note "The workflow_run payload carried no pull request; asking which ones contain ${HEAD_SHA}."
    candidates="$(
        gh api "repos/${REPO}/commits/${HEAD_SHA}/pulls" \
            --jq ".[] | select(.head.sha == \"${HEAD_SHA}\") | .number" 2>/dev/null || true
    )"
fi
[ -n "$candidates" ] || fail "Couldn't establish which pull request ${HEAD_SHA} belongs to."

# The artifact's number is a *selection* among those, for the case where a commit is
# the head of more than one pull request. It can't add one.
selected=""
for number in $candidates; do
    case "$number" in
        *[!0-9]* | "") continue ;;
    esac
    if [ "$number" = "$META_PR" ]; then
        selected="$number"
    fi
done

if [ -z "$selected" ]; then
    fail "metadata.json claims PR #${META_PR}, which isn't one of the pull requests GitHub associates with ${HEAD_SHA}:
$(printf '%s' "$candidates" | tr '\n' ' ')"
fi

note "Publishing PR #${selected} at ${HEAD_SHA}."
emit true true "$selected" "pr-${selected}/${HEAD_SHA}" ""
