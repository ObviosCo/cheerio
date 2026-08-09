import Foundation
import Testing

@testable import CheerioKit

@Suite struct TranscriptTimestampTests {
    @Test func firstSegmentIsAlwaysMarked() {
        let marked = TranscriptTimestamp.markedIndices(startTimes: [0, 3, 8])
        #expect(marked.contains(0))
    }

    @Test func onlyTheFirstSegmentOfEachNewMinuteIsMarked() {
        // 1-2s turns, the density ARCHITECTURE.md's diarization verification saw in
        // a real recording — every one of these lands in minute 0 except the last.
        let startTimes: [TimeInterval] = [0, 1.5, 3, 4.5, 6, 61]
        let marked = TranscriptTimestamp.markedIndices(startTimes: startTimes)
        #expect(marked == [0, 5])
    }

    @Test func thePolicyComparesAgainstTheLastMarkNotEveryMinuteEverSeen() {
        // Out-of-order arrival shouldn't happen for a sorted transcript, but this
        // pins the actual comparison — "differs from the last mark," not "never
        // marked before" — rather than leaving it implicit. A drop back to minute 0
        // after minute 1 has already been marked reads as a new minute again.
        let startTimes: [TimeInterval] = [0, 65, 30]
        let marked = TranscriptTimestamp.markedIndices(startTimes: startTimes)
        #expect(marked == [0, 1, 2])
    }

    @Test func emptyInputMarksNothing() {
        #expect(TranscriptTimestamp.markedIndices(startTimes: []).isEmpty)
    }

    @Test func formatsUnderAnHourAsMinutesAndSeconds() {
        #expect(TranscriptTimestamp.format(0) == "0:00")
        #expect(TranscriptTimestamp.format(65) == "1:05")
        #expect(TranscriptTimestamp.format(599.9) == "9:59")
    }

    @Test func formatsAnHourOrMoreWithAnHoursComponent() {
        #expect(TranscriptTimestamp.format(3600) == "1:00:00")
        #expect(TranscriptTimestamp.format(3665) == "1:01:05")
    }

    @Test func negativeIntervalsClampToZeroRatherThanUnderflow() {
        #expect(TranscriptTimestamp.format(-5) == "0:00")
    }
}
