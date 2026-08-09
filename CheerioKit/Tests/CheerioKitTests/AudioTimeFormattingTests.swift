import Foundation
import Testing

@testable import CheerioKit

@Suite struct AudioTimeFormattingTests {
    @Test func zeroIsZeroColonZeroZero() {
        #expect(AudioTimeFormatting.string(from: 0) == "0:00")
    }

    @Test func secondsUnderAMinuteArePadded() {
        #expect(AudioTimeFormatting.string(from: 5) == "0:05")
    }

    @Test func roundsDownRatherThanUp() {
        // A scrubber label ticking to "1:06" before the 66th second has actually
        // elapsed would drift ahead of the audio it's describing.
        #expect(AudioTimeFormatting.string(from: 65.9) == "1:05")
    }

    @Test func minutesStayUnpaddedPastNine() {
        #expect(AudioTimeFormatting.string(from: 725) == "12:05")
    }

    @Test func growsToHoursPastSixtyMinutes() {
        #expect(AudioTimeFormatting.string(from: 3_661) == "1:01:01")
    }

    @Test func negativeSecondsClampToZero() {
        #expect(AudioTimeFormatting.string(from: -1) == "0:00")
    }

    @Test func nonFiniteValuesClampToZero() {
        #expect(AudioTimeFormatting.string(from: .nan) == "0:00")
        #expect(AudioTimeFormatting.string(from: .infinity) == "0:00")
    }
}
