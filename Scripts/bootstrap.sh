#!/bin/bash
#
# Gets a fresh checkout to a buildable state.
#
#     ./Scripts/bootstrap.sh
#
# The order here matters, which is the whole reason this script exists. The
# diarization model has to be on disk *before* `xcodegen generate` runs:
# project.yml references the .mlmodelc as a folder reference, and XcodeGen
# validates that the path exists before it will write a project. Run generate
# first on a fresh clone and you get
#
#     Spec validation error: Target "Cheerio" has a missing source directory
#     .../Sortformer_v2.1.mlmodelc
#
# which names a file you have never heard of and says nothing about the fetch
# script. The pre-build phase in project.yml can't help either — you can't get
# a build phase until you have a project.
#
# Every step is idempotent, so re-running this is cheap and safe.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

fail() {
    printf '\n\033[31m✗\033[0m %s\n\n' "$1" >&2
    exit 1
}

step() {
    printf '\033[34m→\033[0m %s\n' "$1"
}

# 1. XcodeGen. The .xcodeproj is generated, never committed.
if ! command -v xcodegen >/dev/null 2>&1; then
    fail "xcodegen not found. Install it with:

    brew install xcodegen"
fi
step "$(xcodegen --version 2>/dev/null | head -1 | sed 's/^Version: /xcodegen /') found"

# 2. A full Xcode, not just the Command Line Tools. The CLT ship the SDK but not
#    the SwiftData and FoundationModels macro plugins, and the build fails on
#    missing macros without ever mentioning xcode-select.
developer_dir="$(xcode-select -p 2>/dev/null || true)"
case "$developer_dir" in
    ""|*CommandLineTools*)
        fail "Xcode is not selected — xcode-select points at '${developer_dir:-nothing}'.
  The Command Line Tools alone cannot build this: they ship the SDK but not the
  SwiftData and FoundationModels macro plugins. Install Xcode 26+, then run:

    sudo xcode-select -s /Applications/Xcode.app"
        ;;
esac
# ...and a new enough one. An Xcode older than 26 has no macOS 26 SDK, so it fails
# later on missing SpeechAnalyzer/FoundationModels symbols rather than on anything
# that points at the toolchain.
# The `|| true` matters: under `set -e` with pipefail, a failing xcodebuild would
# abort here silently and the message below would never be reached.
xcode_version="$(xcodebuild -version 2>/dev/null | awk 'NR==1 {print $2}' || true)"
if [ -z "$xcode_version" ]; then
    fail "Could not read the Xcode version from 'xcodebuild -version'.
  If Xcode was just installed, it may still need its license accepted:

    sudo xcodebuild -license accept"
fi
if [ "${xcode_version%%.*}" -lt 26 ]; then
    fail "Xcode ${xcode_version} is too old — this project needs Xcode 26 or later.
  It targets macOS 26 and uses SpeechAnalyzer and FoundationModels, which are not
  in any earlier SDK."
fi
step "Xcode ${xcode_version} at ${developer_dir}"

# 3. The diarization model (~93 MB, NVIDIA Open Model License, not committed).
#    Checksummed and idempotent — a no-op once it's present and intact.
step "Fetching the diarization model"
"${SCRIPT_DIR}/fetch-models.sh"

# 4. Generate the project. Exits non-zero if anything above left a gap.
step "Generating Cheerio.xcodeproj"
cd "$ROOT"
xcodegen generate >/dev/null

printf '\n\033[32m✓\033[0m Ready. Open the project and build the Cheerio scheme:\n\n'
printf '    open Cheerio.xcodeproj\n\n'
printf 'Re-run this script after adding or removing source files, or the build\n'
printf 'will not see them.\n'
