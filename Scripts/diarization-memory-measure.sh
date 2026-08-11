#!/bin/bash
#
# Demonstrates issue #7's fix: diarization used to read a whole channel into one
# [Float] array before Sortformer ever ran — ~230 MB for a 60-minute side — and
# now reads it in bounded windows instead.
#
#     Scripts/diarization-memory-measure.sh [--minutes N] [--model /path/to/Sortformer_v2.1.mlmodelc]
#
# Generates a synthetic mono 48 kHz CAF of the given length (default 10, kept
# short so the script is fast to run by default — pass --minutes 60 for the
# number that matches issue #7's own "Call with Mary" framing, which takes a few
# minutes since it's running real model inference, not a stand-in) and runs the
# old and new loading strategies through the REAL bundled model and the REAL
# production code, each as its own `swift test` process so `getrusage`'s
# `ru_maxrss` — a high-water mark that never drops within a process — gives each
# path a clean baseline instead of the second one inheriting the first's peak.
#
# Earlier versions of this script measured a hand-rolled stand-in that read and
# discarded raw audio without ever calling into FluidAudio — which validated that
# *reading a file in windows* doesn't leak, but not that *diarizing* it doesn't:
# SortformerDiarizer.addAudio(_:) alone doesn't drain its own internal buffers
# (see SpeakerAttributionService.swift's comment on why `process(samples:)` is
# required, not `addAudio`), so that version's flat "after" number would have
# stayed flat even with that bug still in place. This version runs the actual
# `SpeakerAttributionService.attribute` — the two `swift test` targets it drives
# are `DiarizationMemoryTests.oldWholeFilePathPeakRSS` (mirrors the pre-fix
# `AudioConverter.resampleAudioFile` + `SortformerDiarizer.processComplete` call,
# via `DiarizationMemoryHarness`) and `.newWindowedPathPeakRSS` (calls
# `SpeakerAttributionService.attribute` directly).
#
# This reports numbers and stops; there's no pass/fail.

set -euo pipefail

minutes=10
model=""

require_value() {
    if [ $# -lt 2 ]; then
        echo "$1 requires a value." >&2
        exit 1
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --minutes)
            require_value "$@"
            minutes="$2"
            shift 2
            ;;
        --model)
            require_value "$@"
            model="$2"
            shift 2
            ;;
        -h | --help)
            sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unrecognized argument: $1 (--help for usage)" >&2
            exit 1
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -z "$model" ]; then
    model="${ROOT}/Cheerio/Resources/Models/Sortformer_v2.1.mlmodelc"
fi
if [ ! -d "$model" ]; then
    echo "No model at $model — run ./Scripts/bootstrap.sh first, or pass --model." >&2
    exit 1
fi

step() {
    printf '\033[34m→\033[0m %s\n' "$1"
}

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
caf="$workdir/synthetic-${minutes}min.caf"

step "Generating a synthetic ${minutes}-minute mono 48kHz CAF at $caf"
swift - "$caf" "$minutes" <<'SWIFT'
import AVFoundation
import Foundation

let path = CommandLine.arguments[1]
let minutes = Double(CommandLine.arguments[2])!
let sampleRate = 48_000.0
let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
let file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: format.settings)

// Written in windows rather than one huge buffer — this script measures the fix,
// it shouldn't need the bug to build its own fixture.
let totalFrames = AVAudioFramePosition(minutes * 60 * sampleRate)
let windowFrames: AVAudioFrameCount = 1 << 20
var written: AVAudioFramePosition = 0
while written < totalFrames {
    let framesThisWindow = AVAudioFrameCount(min(AVAudioFramePosition(windowFrames), totalFrames - written))
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesThisWindow) else {
        FileHandle.standardError.write("couldn't allocate a write buffer\n".data(using: .utf8)!)
        exit(1)
    }
    buffer.frameLength = framesThisWindow
    let data = buffer.floatChannelData![0]
    for i in 0..<Int(framesThisWindow) {
        data[i] = sin(Float(written + AVAudioFramePosition(i)) * 0.01) * 0.2
    }
    try file.write(from: buffer)
    written += AVAudioFramePosition(framesThisWindow)
}
print("  wrote \(written) frames (\(String(format: "%.1f", Double(written) / sampleRate / 60)) minutes)")
SWIFT

echo
step "Old path: whole-channel load + processComplete (DiarizationMemoryHarness.diarizeWholeFile)"
old_output="$(cd "${ROOT}/CheerioKit" && CHEERIO_SORTFORMER_MODEL="$model" CHEERIO_DIARIZATION_MEMORY_AUDIO="$caf" swift test --filter oldWholeFilePathPeakRSS 2>&1)" \
    || { echo "$old_output"; exit 1; }
echo "$old_output" | grep -E "PEAK_RSS|passed after|FAIL" | sed 's/^/  /'

echo
step "New path: SpeakerAttributionService.attribute (the real production call)"
new_output="$(cd "${ROOT}/CheerioKit" && CHEERIO_SORTFORMER_MODEL="$model" CHEERIO_DIARIZATION_MEMORY_AUDIO="$caf" swift test --filter newWindowedPathPeakRSS 2>&1)" \
    || { echo "$new_output"; exit 1; }
echo "$new_output" | grep -E "PEAK_RSS|passed after|FAIL" | sed 's/^/  /'

echo
echo "Each path ran as its own 'swift test' process so ru_maxrss (a high-water"
echo "mark that never drops within a process) reflects only that path, not"
echo "whichever ran first. Both go through the real bundled model."
