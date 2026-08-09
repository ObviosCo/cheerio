#!/bin/bash
#
# Demonstrates issue #7's fix: diarization used to read a whole channel into one
# [Float] array before Sortformer ever ran — ~230 MB for a 60-minute side — and
# now reads it in bounded windows instead.
#
#     Scripts/diarization-memory-measure.sh [--minutes N]
#
# Generates a synthetic mono 48 kHz CAF of the given length (default 60, matching
# issue #7's own "Call with Mary" example) and runs the old and new loading
# strategies as two separate processes, each printing its own peak resident set
# size (`getrusage`'s `ru_maxrss`, which is a high-water mark that never drops
# within a process — comparing two phases in one run would conflate them, so each
# gets a clean baseline instead).
#
# Swift, not sox/ffmpeg, and no FluidAudio import: this isolates exactly the piece
# issue #7 is about — the intermediate [Float] array — using plain AVFoundation.
# The "old" script mirrors `AudioConverter.resampleAudioFile` (FluidAudio 0.15.5)
# byte for byte; the "new" one mirrors `ChunkedAudioReader.read` (CheerioKit) plus
# discarding each window once it's been "handed off", standing in for
# `diarizer.addAudio(_:)` never retaining what it's given. Neither script touches
# Sortformer or the bundled model — the model and the diarizer's own internal
# state are unaffected by either path (see SpeakerAttributionService.swift); this
# is measuring the one allocation that scales with recording length.
#
# Like aec-ab-measure.sh, this reports numbers and stops; there's no pass/fail.

set -euo pipefail

minutes=60

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
step "Old path: whole-channel load (AudioConverter.resampleAudioFile's pattern)"
swift - "$caf" <<'SWIFT'
import AVFoundation
import Foundation

let path = CommandLine.arguments[1]
let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
let format = file.processingFormat

// This is AudioConverter.resampleAudioFile (FluidAudio 0.15.5), reproduced
// verbatim: it reads the file in chunks, but appends every one into a single
// array that lives for the whole call. That array is the ~230 MB-for-60-minutes
// allocation issue #7 is about — SpeakerAttributionService no longer builds it.
let chunkSize = max(4096, Int(format.sampleRate))
var monoSamples: [Float] = []
monoSamples.reserveCapacity(Int(file.length))

while file.framePosition < file.length {
    let remaining = Int(file.length - file.framePosition)
    let framesToRead = AVAudioFrameCount(min(chunkSize, remaining))
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead) else { break }
    try file.read(into: buffer, frameCount: framesToRead)
    guard buffer.frameLength > 0 else { break }
    let data = buffer.floatChannelData![0]
    monoSamples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
}

var usage = rusage()
getrusage(RUSAGE_SELF, &usage)
print("  samples=\(monoSamples.count) peakRSS=\(usage.ru_maxrss) bytes")
SWIFT

echo
step "New path: bounded windows, discarded after use (ChunkedAudioReader's pattern)"
swift - "$caf" <<'SWIFT'
import AVFoundation
import Foundation

let path = CommandLine.arguments[1]
let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
let windowFrames: AVAudioFrameCount = 1 << 20

var totalSamples = 0
// Guard on framePosition, not an empty read: AVAudioFile.read(into:) throws once
// position has reached length rather than returning zero frames — and can also
// return fewer frames than requested well before that point, so the next
// iteration's `remaining` is computed from the actual position, not an assumed
// stride (see ChunkedAudioReaderTests for a measured instance of the short read).
while file.framePosition < file.length {
    let remaining = file.length - file.framePosition
    let framesToRead = AVAudioFrameCount(min(AVAudioFramePosition(windowFrames), remaining))
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: framesToRead) else { break }
    try file.read(into: buffer, frameCount: framesToRead)
    guard buffer.frameLength > 0 else { break }
    // Stand-in for handing the window straight to diarizer.addAudio(_:) and
    // moving on: nothing from this window survives past this iteration.
    let data = buffer.floatChannelData![0]
    let chunk = Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    totalSamples += chunk.count
}

var usage = rusage()
getrusage(RUSAGE_SELF, &usage)
print("  samples=\(totalSamples) peakRSS=\(usage.ru_maxrss) bytes")
SWIFT

echo
echo "Each path ran as its own process so ru_maxrss (a high-water mark that never"
echo "drops within a process) reflects only that path, not whichever ran first."
