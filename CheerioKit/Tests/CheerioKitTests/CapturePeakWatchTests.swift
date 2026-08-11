import Foundation
import Testing

@testable import CheerioKit

@Suite struct CapturePeakWatchTests {
    @Test func startsAtSilence() {
        let watch = CapturePeakWatch()
        #expect(watch.peak == 0)
        #expect(watch.verdict == .silence(peak: 0))
    }

    @Test func accumulatesTheLoudestReading() {
        let watch = CapturePeakWatch()
        watch.record(peak: 0.2)
        watch.record(peak: 0.5)
        watch.record(peak: 0.3)
        #expect(watch.peak == 0.5)
    }

    @Test func quieterReadingsNeverRegressThePeak() {
        let watch = CapturePeakWatch()
        watch.record(peak: 0.5)
        watch.record(peak: 0)
        watch.record(peak: 0.0001)
        #expect(watch.peak == 0.5)
    }

    /// NaN's bit pattern sorts above every real value; infinity and negatives are
    /// not levels at all. None of them may disturb the max.
    @Test func nonFiniteAndNegativeReadingsAreDropped() {
        let watch = CapturePeakWatch()
        watch.record(peak: 0.25)
        watch.record(peak: .nan)
        watch.record(peak: .infinity)
        watch.record(peak: -0.9)
        #expect(watch.peak == 0.25)
    }

    /// `record` is lock-free by design (it runs on the realtime audio thread);
    /// hammering it concurrently must still settle on the true max.
    @Test func concurrentRecordingSettlesOnTheTrueMax() async {
        let watch = CapturePeakWatch()
        await withTaskGroup(of: Void.self) { group in
            for lane in 1...8 {
                group.addTask {
                    for step in 1...1000 {
                        watch.record(peak: Float(lane * step) / 8000)
                    }
                }
            }
        }
        #expect(watch.peak == 1)
    }

    @Test func dBFSConversion() throws {
        #expect(CapturePeakWatch.Verdict.dBFS(fromLinear: 1) == 0)
        let half = try #require(CapturePeakWatch.Verdict.dBFS(fromLinear: 0.5))
        #expect(abs(half - -6.0206) < 0.001)
        let tenth = try #require(CapturePeakWatch.Verdict.dBFS(fromLinear: 0.1))
        #expect(abs(tenth - -20) < 0.001)
        #expect(CapturePeakWatch.Verdict.dBFS(fromLinear: 0) == nil)
    }

    @Test func peaksAboveTheFloorReadAsSignal() {
        // 0.01 is -40 dBFS — quiet, but unambiguously captured audio.
        #expect(CapturePeakWatch.Verdict(peak: 0.01) == .signal(peak: 0.01))
        #expect(CapturePeakWatch.Verdict(peak: 1) == .signal(peak: 1))
    }

    @Test func peaksBelowTheFloorReadAsSilence() {
        // 0.0005 is about -66 dBFS: nonzero residue, but nothing resembling speech.
        #expect(CapturePeakWatch.Verdict(peak: 0.0005) == .silence(peak: 0.0005))
        #expect(CapturePeakWatch.Verdict(peak: 0) == .silence(peak: 0))
    }

    @Test func peakDescriptionRendersDBFS() {
        let verdict = CapturePeakWatch.Verdict(peak: 0.5)
        #expect(verdict.peakDescription == "-6.0 dBFS")
    }

    /// Exact zero is a different diagnosis from "very quiet" — a denied capture
    /// delivers pure digital zeroes — so it must be named, not printed as "-inf".
    @Test func peakDescriptionNamesPureZeroes() {
        let verdict = CapturePeakWatch.Verdict(peak: 0)
        #expect(verdict.peakDescription == "every sample zero")
    }
}
