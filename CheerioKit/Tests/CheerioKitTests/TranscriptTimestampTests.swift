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

    @Test func aMinuteAlreadyStampedStaysUnstampedEvenIfRevisitedLater() {
        // Once minute 1 has a stamp, a later entry that falls back into minute 0
        // doesn't get a second one — the policy tracks every minute stamped so
        // far, not just the most recent, which is what makes it safe for
        // out-of-order arrival (see the live-transcript test below).
        let startTimes: [TimeInterval] = [0, 65, 30]
        let marked = TranscriptTimestamp.markedIndices(startTimes: startTimes)
        #expect(marked == [0, 1])
    }

    @Test func outOfOrderArrivalFromTwoChannelsStillStampsEachMinuteOnce() {
        // The live transcript's mic and system channels finalize on independent
        // schedules (`CaptureSession.startCapturing`'s two consumer tasks), so a
        // 61s line can render before a 58s one. This is that interleaving,
        // reduced to its minute boundaries: minute 0 arrives, minute 1 arrives,
        // then minute 0 again — the third entry must not get a second minute-0
        // stamp.
        let startTimes: [TimeInterval] = [59, 61, 58]
        let marked = TranscriptTimestamp.markedIndices(startTimes: startTimes)
        #expect(marked == [0, 1])
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
