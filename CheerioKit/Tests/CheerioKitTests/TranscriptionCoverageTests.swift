import AVFoundation
import Foundation
import Testing

@testable import CheerioKit

@Suite struct TranscriptionCoverageTests {
    /// Issue #174 in one assertion: −3.3 dBFS across 58 minutes on a 3 ch / 24 kHz
    /// mic, and not a single transcript segment.
    @Test func signalWithoutTranscriptIsTheBug() {
        let coverage = TranscriptionCoverage(
            channel: .me,
            carriedSignal: true,
            peak: 0.683,
            format: CapturedAudioFormat(channelCount: 3, sampleRate: 24_000),
            segmentCount: 0)
        #expect(coverage.verdict == .signalWithoutTranscript)
        let diagnosis = coverage.diagnosis
        #expect(diagnosis != nil)
        // The three facts that make it actionable without a debugger.
        #expect(diagnosis?.contains("me") == true)
        #expect(diagnosis?.contains("3 ch / 24000 Hz") == true)
        #expect(diagnosis?.contains("-3.3 dBFS") == true)
    }

    @Test func signalWithTranscriptIsConsistent() {
        let coverage = TranscriptionCoverage(
            channel: .me,
            carriedSignal: true,
            peak: 0.5,
            format: CapturedAudioFormat(channelCount: 1, sampleRate: 48_000),
            segmentCount: 12)
        #expect(coverage.verdict == .consistent)
        #expect(coverage.diagnosis == nil)
    }

    /// A quiet channel is somebody else's diagnosis — `CapturePeakWatch` and
    /// `SilenceWatch` already log it where it happened, with the reasons. This check
    /// staying quiet is what keeps a solo recording (no far end, so no system audio)
    /// from crying wolf on every meeting.
    @Test func aSilentChannelIsNotThisChecksFinding() {
        let coverage = TranscriptionCoverage(
            channel: .them,
            carriedSignal: false,
            format: CapturedAudioFormat(channelCount: 2, sampleRate: 48_000),
            segmentCount: 0)
        #expect(coverage.verdict == .silentChannel)
        #expect(coverage.diagnosis == nil)
    }

    /// Text with no measured signal is not a lost transcript, so it isn't reported
    /// either — the mic's peak is a whole-recording max, but the system tap's watch
    /// only samples the opening seconds and can legitimately miss a call that starts
    /// after them.
    @Test func transcriptWithoutMeasuredSignalIsNotReported() {
        let coverage = TranscriptionCoverage(channel: .them, carriedSignal: false, segmentCount: 40)
        #expect(coverage.verdict == .silentChannel)
        #expect(coverage.diagnosis == nil)
    }

    /// The system tap has no level meter to piggyback on, so its report carries no
    /// peak — the verdict and its wording still have to work.
    @Test func aChannelWithoutALevelMeasurementStillDiagnoses() {
        let coverage = TranscriptionCoverage(
            channel: .them,
            carriedSignal: true,
            format: CapturedAudioFormat(channelCount: 2, sampleRate: 48_000),
            segmentCount: 0)
        #expect(coverage.verdict == .signalWithoutTranscript)
        let diagnosis = coverage.diagnosis
        #expect(diagnosis?.contains("them") == true)
        #expect(diagnosis?.contains("2 ch / 48000 Hz") == true)
        #expect(diagnosis?.contains("level unmeasured") == true)
    }

    /// A capture source that failed before it could report a format still has to
    /// produce a readable line rather than an interpolated nil.
    @Test func anUnknownFormatIsNamedAsSuch() {
        let coverage = TranscriptionCoverage(channel: .me, carriedSignal: true, peak: 0.25, segmentCount: 0)
        let diagnosis = coverage.diagnosis
        #expect(diagnosis?.contains("an unrecorded format") == true)
        #expect(diagnosis?.contains("nil") == false)
    }

    /// The capture sources build these from an `AVAudioFormat` they own; the
    /// scalars have to survive the copy, since they're the whole diagnosis.
    @Test func capturedFormatCopiesTheScalarsOffAnAVAudioFormat() throws {
        var description = AudioStreamBasicDescription(
            mSampleRate: 24_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 12,
            mFramesPerPacket: 1,
            mBytesPerFrame: 12,
            mChannelsPerFrame: 3,
            mBitsPerChannel: 32,
            mReserved: 0)
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 3))
        let format = try #require(AVAudioFormat(streamDescription: &description, channelLayout: layout))

        let captured = CapturedAudioFormat(format)
        #expect(captured == CapturedAudioFormat(channelCount: 3, sampleRate: 24_000))
        #expect(captured.description == "3 ch / 24000 Hz")
    }
}
