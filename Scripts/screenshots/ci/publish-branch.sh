#!/bin/bash
#
# Puts a run's captures on the orphan `screenshots` branch, where raw.githubusercontent
# can serve them into a PR comment.
#
#     ./Scripts/screenshots/ci/publish-branch.sh --dir <pngs> --prefix pr-42/<sha> \
#         [--branch screenshots] [--max-bytes 10485760] [--prune-repo owner/name]
#
# **The branch is disposable history.** Nothing on it is source, nothing on it is ever
# merged, and it shares no commit with `main` — it starts from an empty tree, so a
# clone that doesn't ask for it pays nothing for it. If it ever gets unwieldy,
# `git push origin --delete screenshots` is a supported move: the next run makes a new
# one. Two things keep it from getting there in the first place:
#
# - each push replaces the earlier captures for the same PR rather than adding to
#   them, so an open PR costs one directory however many times CI runs on it;
# - `--prune-repo` drops the directories of PRs that are no longer open.
#
# Both only bound the *tip*. The objects behind old commits stay until the branch is
# deleted, which is the argument for deleting it rather than gardening it.
#
# Run from inside a checkout with a pushable `origin` — in CI, the one actions/checkout
# left credentials in. Nothing here touches the working tree or the current branch: the
# captures are committed from a detached `git worktree` of their own.

set -euo pipefail

DIR=""
PREFIX=""
BRANCH="screenshots"
MAX_BYTES=$((10 * 1024 * 1024))
PRUNE_REPO=""

while [ $# -gt 0 ]; do
    case "$1" in
        --dir) DIR="$2"; shift 2 ;;
        --prefix) PREFIX="$2"; shift 2 ;;
        --branch) BRANCH="$2"; shift 2 ;;
        --max-bytes) MAX_BYTES="$2"; shift 2 ;;
        --prune-repo) PRUNE_REPO="$2"; shift 2 ;;
        -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

[ -n "$DIR" ] || { echo "--dir is required" >&2; exit 2; }
[ -n "$PREFIX" ] || { echo "--prefix is required" >&2; exit 2; }
[ -d "$DIR" ] || { echo "No directory at ${DIR}" >&2; exit 1; }
case "$PREFIX" in
    /*|*..*) echo "--prefix must be a relative path with no '..': ${PREFIX}" >&2; exit 2 ;;
esac

REPO_ROOT="$(git rev-parse --show-toplevel)"

# The upload budget, checked before anything is committed. A run that blew past it is
# a bug in the capture pass — a full-screen shot where a window was meant, say — and
# failing here keeps that bug out of the branch's history rather than in it forever.
TOTAL="$(find "$DIR" -type f -name '*.png' -exec stat -f %z {} + | awk '{sum += $1} END {print sum + 0}')"
if [ "$TOTAL" = 0 ]; then
    echo "No .png files in ${DIR}." >&2
    exit 1
fi
if [ "$TOTAL" -gt "$MAX_BYTES" ]; then
    printf 'Captures total %s bytes, over the %s-byte budget. Refusing to publish.\n' \
        "$TOTAL" "$MAX_BYTES" >&2
    exit 1
fi

WORKTREE="$(mktemp -d)/screenshots"
cleanup() {
    git -C "$REPO_ROOT" worktree remove --force "$WORKTREE" 2>/dev/null || true
    rm -rf "$(dirname "$WORKTREE")"
}
trap cleanup EXIT

# FETCH_HEAD rather than a remote-tracking ref: actions/checkout narrows origin's
# refspec to the one branch it checked out, so refs/remotes/origin/<branch> may never
# come into existence however many times this fetches.
if git -C "$REPO_ROOT" fetch --quiet origin "$BRANCH" 2>/dev/null; then
    git -C "$REPO_ROOT" worktree add --quiet --detach "$WORKTREE" FETCH_HEAD
else
    # First run: an orphan root commit, made with plumbing so that getting one costs
    # no checkout in the main worktree. `hash-object -t tree /dev/null` is the empty
    # tree, and a commit on it has no parent and no files.
    EMPTY_TREE="$(git -C "$REPO_ROOT" hash-object -t tree /dev/null)"
    ROOT="$(git -C "$REPO_ROOT" commit-tree "$EMPTY_TREE" -m "Start the screenshots branch")"
    git -C "$REPO_ROOT" worktree add --quiet --detach "$WORKTREE" "$ROOT"
    echo "Created ${BRANCH} from an empty tree — it had no remote copy."
fi

# Directories for PRs that have since closed. One `gh` call for the open set, so a
# branch holding a hundred stale directories still costs one request. Anything that
# goes wrong in here is a note rather than a failure: pruning is housekeeping, and
# publishing this run's captures is what the job came to do.
prune() {
    local open dir number limit=200
    if ! open="$(gh pr list --repo "$PRUNE_REPO" --state open --limit "$limit" --json number --jq '.[].number' 2>/dev/null)"; then
        echo "Couldn't list open PRs for ${PRUNE_REPO}; skipping the prune."
        return 0
    fi
    # A truncated list would read as "these PRs closed" and delete the captures of
    # PRs that are merely off the end of it.
    if [ "$(printf '%s\n' "$open" | grep -c .)" -ge "$limit" ]; then
        echo "More than ${limit} open PRs; skipping the prune rather than guessing."
        return 0
    fi
    for dir in "${WORKTREE}"/pr-*; do
        [ -d "$dir" ] || continue
        number="$(basename "$dir")"
        number="${number#pr-}"
        if ! printf '%s\n' "$open" | grep -qx "$number"; then
            rm -rf "$dir"
            echo "Pruned ${dir##*/} — that PR is closed."
        fi
    done
}

# Everything that changes the tree, so the retry below can redo it on top of whatever
# another run pushed in the meantime. Returns nonzero when there's nothing to commit.
apply() {
    local parent
    parent="$(dirname "$PREFIX")"
    # One directory per PR: a rerun replaces the last run's captures instead of
    # stacking another set of PNGs beside them.
    if [ "$parent" != "." ]; then
        rm -rf "${WORKTREE:?}/${parent}"
    fi

    # Pruned before this run's captures are written, not after: a PR that closed
    # while the job was running would otherwise have its directory deleted a second
    # after being filled, leaving the comment pointing at nothing.
    #
    # An `[ … ] && prune` one-liner would exit the whole script under `set -e` on the
    # run where PRUNE_REPO is empty, since a failed AND-list outside a condition is
    # itself a failure.
    if [ -n "$PRUNE_REPO" ]; then
        prune
    fi

    mkdir -p "${WORKTREE}/${PREFIX}"
    cp "$DIR"/*.png "${WORKTREE}/${PREFIX}/"

    git -C "$WORKTREE" add --all
    if git -C "$WORKTREE" diff --cached --quiet; then
        echo "Nothing changed on ${BRANCH}."
        return 1
    fi
    git -C "$WORKTREE" \
        -c "user.name=${GIT_COMMIT_NAME:-github-actions[bot]}" \
        -c "user.email=${GIT_COMMIT_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}" \
        commit --quiet -m "Screenshots for ${PREFIX}"
}

# Runs on different PRs push to the same branch, so losing the race is ordinary rather
# than exceptional: take the new tip and redo the work on top of it.
for attempt in 1 2 3; do
    if ! apply; then
        exit 0
    fi
    if git -C "$WORKTREE" push --quiet origin "HEAD:refs/heads/${BRANCH}"; then
        echo "Published ${PREFIX} to ${BRANCH}."
        exit 0
    fi
    echo "Push attempt ${attempt} lost the race; refetching ${BRANCH}."
    git -C "$REPO_ROOT" fetch --quiet origin "$BRANCH"
    # Resolved here rather than passed on as `FETCH_HEAD`: that ref is per-worktree,
    # so the name means nothing in the linked worktree the captures are staged in.
    TIP="$(git -C "$REPO_ROOT" rev-parse FETCH_HEAD)"
    git -C "$WORKTREE" reset --quiet --hard "$TIP"
done

echo "Couldn't push ${BRANCH} after three attempts." >&2
exit 1
