#!/bin/bash
#
# Measures whether acoustic echo cancellation (issue #5) is actually doing anything,
# instead of judging it by ear.
#
#     Scripts/aec-ab-measure.sh --caf-before <me.caf> --caf-after <me.caf>
#     Scripts/aec-ab-measure.sh --me-transcript <file> --them-transcript <file>
#     Scripts/aec-ab-measure.sh --caf-before <me.caf> --caf-after <me.caf> \
#         --me-transcript <file> --them-transcript <file>
#
# This is for the maintainer to run against real recordings — it cannot be run in
# CI or by an agent, because producing the inputs means recording an actual meeting
# with actual speaker playback, which is exactly what nothing in this repo's
# automation is allowed to do (see CLAUDE.md: never capture the microphone or play
# audio from an automated context).
#
# Two independent checks, run whichever inputs you have:
#
# 1. CAF-peak A/B (--caf-before / --caf-after). Record the same speaker-playback
#    content twice, back to back — once with Recording mode set to "In Person"
#    (AEC off, `before`) and once set to "Video Call" (AEC on, `after`) — and pass
#    the two resulting `me.caf` files. This reports peak and RMS dBFS for each and
#    the delta between them, the same discipline CLAUDE.md already uses for the
#    sandboxed-vs-unsandboxed tap measurement (`peak=0.0` vs `-1.8 dBFS`). A bigger
#    negative delta after enabling AEC means less of the speaker signal is reaching
#    the mic channel. There's no single dB threshold that means "fixed" — judge it
#    against how loud the speaker playback actually was.
#
# 2. Transcript dedup (--me-transcript / --them-transcript). From a *single*
#    Video Call recording made during the #5 repro (speaker playback, AEC on),
#    export or copy the Me and Them channel transcripts to two text files. This
#    reports what fraction of word bigrams they share. High overlap means the
#    remote speech is still landing on both channels — AEC isn't working. Low
#    overlap means the mic is mostly hearing only you, which is the fix working.
#
# Both checks print numbers and stop; neither one passes or fails the script, since
# only a human with the actual recording conditions can say what the numbers mean.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() {
    printf '\n\033[31m✗\033[0m %s\n\n' "$1" >&2
    exit 1
}

step() {
    printf '\033[34m→\033[0m %s\n' "$1"
}

caf_before=""
caf_after=""
me_transcript=""
them_transcript=""

# Under `set -u`, reading $2 for a value-taking option with nothing after it is an
# unbound-variable error, not this script's own usage message. Checking $# first
# means a trailing `--caf-before` with no value gets the same fail() as any other
# bad invocation, instead of a shell error a level below it.
require_value() {
    if [ $# -lt 2 ]; then
        fail "$1 requires a value."
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --caf-before)
            require_value "$@"
            caf_before="$2"
            shift 2
            ;;
        --caf-after)
            require_value "$@"
            caf_after="$2"
            shift 2
            ;;
        --me-transcript)
            require_value "$@"
            me_transcript="$2"
            shift 2
            ;;
        --them-transcript)
            require_value "$@"
            them_transcript="$2"
            shift 2
            ;;
        -h | --help)
            sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            fail "Unrecognized argument: $1 (--help for usage)"
            ;;
    esac
done

if [ -z "$caf_before" ] && [ -z "$caf_after" ] && [ -z "$me_transcript" ] && [ -z "$them_transcript" ]; then
    fail "Nothing to measure — pass --caf-before/--caf-after, --me-transcript/--them-transcript, or both. --help for details."
fi

ran_something=0

# --- Check 1: CAF-peak A/B ------------------------------------------------------

if [ -n "$caf_before" ] || [ -n "$caf_after" ]; then
    [ -n "$caf_before" ] && [ -n "$caf_after" ] || fail "--caf-before and --caf-after must both be given together."
    [ -f "$caf_before" ] || fail "No such file: $caf_before"
    [ -f "$caf_after" ] || fail "No such file: $caf_after"
    ran_something=1

    step "CAF-peak A/B: $caf_before (before) vs $caf_after (after)"

    # Swift, not sox/ffmpeg: AVAudioFile is what MeetingAudioRecorder itself writes
    # CAFs with, so this reads them the same way the app does, with no extra
    # dependency beyond the toolchain this repo already requires.
    swift - "$caf_before" "$caf_after" <<'SWIFT'
import AVFoundation
import Foundation

func measure(_ path: String) throws -> (peakDBFS: Double, rmsDBFS: Double) {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: file.fileFormat.sampleRate,
        channels: file.fileFormat.channelCount,
        interleaved: false)!
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
    else {
        throw NSError(domain: "aec-ab-measure", code: 1, userInfo: [NSLocalizedDescriptionKey: "couldn't allocate buffer for \(path)"])
    }
    try file.read(into: buffer)

    let frameCount = Int(buffer.frameLength)
    guard frameCount > 0, let channels = buffer.floatChannelData else {
        return (peakDBFS: -.infinity, rmsDBFS: -.infinity)
    }
    var peak: Float = 0
    var sumSquares: Double = 0
    var sampleCount = 0
    for channel in 0..<Int(format.channelCount) {
        let samples = channels[channel]
        for i in 0..<frameCount {
            let sample = samples[i]
            peak = max(peak, abs(sample))
            sumSquares += Double(sample) * Double(sample)
            sampleCount += 1
        }
    }
    let rms = sampleCount > 0 ? (sumSquares / Double(sampleCount)).squareRoot() : 0
    func dBFS(_ amplitude: Double) -> Double {
        amplitude > 0 ? 20 * log10(amplitude) : -.infinity
    }
    return (peakDBFS: dBFS(Double(peak)), rmsDBFS: dBFS(rms))
}

func format(_ value: Double) -> String {
    value.isFinite ? String(format: "%.1f dBFS", value) : "silent"
}

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

let arguments = CommandLine.arguments
do {
    let before = try measure(arguments[1])
    let after = try measure(arguments[2])
    print("")
    print("  \(pad("", 10))\(pad("peak", 14))\(pad("RMS", 14))")
    print("  \(pad("before", 10))\(pad(format(before.peakDBFS), 14))\(pad(format(before.rmsDBFS), 14))")
    print("  \(pad("after", 10))\(pad(format(after.peakDBFS), 14))\(pad(format(after.rmsDBFS), 14))")
    if before.peakDBFS.isFinite, after.peakDBFS.isFinite {
        print(String(format: "  peak delta: %.1f dB", after.peakDBFS - before.peakDBFS))
    }
    if before.rmsDBFS.isFinite, after.rmsDBFS.isFinite {
        print(String(format: "  RMS delta:  %.1f dB", after.rmsDBFS - before.rmsDBFS))
    }
    print("")
} catch {
    FileHandle.standardError.write("aec-ab-measure: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
SWIFT
fi

# --- Check 2: transcript dedup --------------------------------------------------

if [ -n "$me_transcript" ] || [ -n "$them_transcript" ]; then
    [ -n "$me_transcript" ] && [ -n "$them_transcript" ] || fail "--me-transcript and --them-transcript must both be given together."
    [ -f "$me_transcript" ] || fail "No such file: $me_transcript"
    [ -f "$them_transcript" ] || fail "No such file: $them_transcript"
    ran_something=1

    step "Transcript dedup: $me_transcript vs $them_transcript"

    swift - "$me_transcript" "$them_transcript" <<'SWIFT'
import Foundation

// Word bigrams rather than single words: two transcripts of the same meeting
// share plenty of common single words ("the", "and", a person's name) even with
// no duplication at all, which would understate how distinctive real overlap is.
// Adjacent-word pairs are far less likely to coincide by chance.
func bigrams(of path: String) throws -> Set<String> {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    let words =
        text
        .lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
    guard words.count > 1 else { return [] }
    return Set((0..<(words.count - 1)).map { "\(words[$0]) \(words[$0 + 1])" })
}

let arguments = CommandLine.arguments
do {
    let me = try bigrams(of: arguments[1])
    let them = try bigrams(of: arguments[2])
    guard !me.isEmpty, !them.isEmpty else {
        print("\n  One of the transcripts has fewer than two words — nothing to compare.\n")
        exit(0)
    }
    let shared = me.intersection(them)
    let smaller = min(me.count, them.count)
    let overlapOfSmaller = Double(shared.count) / Double(smaller) * 100
    let jaccard = Double(shared.count) / Double(me.union(them).count) * 100
    print("")
    print("  me: \(me.count) bigrams, them: \(them.count) bigrams, shared: \(shared.count)")
    print(String(format: "  overlap (of the smaller transcript): %.0f%%", overlapOfSmaller))
    print(String(format: "  overlap (Jaccard):                   %.0f%%", jaccard))
    print("")
} catch {
    FileHandle.standardError.write("aec-ab-measure: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
SWIFT
fi

if [ "$ran_something" -eq 0 ]; then
    fail "Nothing to measure — pass --caf-before/--caf-after, --me-transcript/--them-transcript, or both."
fi
