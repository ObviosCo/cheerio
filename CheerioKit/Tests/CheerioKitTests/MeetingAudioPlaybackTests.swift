import AVFoundation
import Foundation
import Testing

@testable import CheerioKit

/// Entirely off `AudioStorage`'s real Application Support container — every test
/// points `channelFileURLs`/`hasPlayableAudio` at its own temp directory instead,
/// the same pattern `AudioOrphanSweepTests` uses.
@Suite struct MeetingAudioPlaybackTests {
    private func makeMeetingDirectory() throws -> URL {
        let root = URL.temporaryDirectory.appending(path: "cheerio-playback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func noAudioDirectoryMeansNothingToPlay() {
        let meeting = Meeting(title: "Standup")
        #expect(MeetingAudioPlayback.channelFileURLs(for: meeting, resolve: { _ in URL.temporaryDirectory }) == [])
        #expect(!MeetingAudioPlayback.hasPlayableAudio(for: meeting, resolve: { _ in URL.temporaryDirectory }))
    }

    @Test func audioDirectoryWithNoFilesOnDiskMeansNothingToPlay() throws {
        let directory = try makeMeetingDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let meeting = Meeting(title: "Standup")
        meeting.audioDirectory = "Meetings/whatever"

        #expect(MeetingAudioPlayback.channelFileURLs(for: meeting, resolve: { _ in directory }) == [])
        #expect(!MeetingAudioPlayback.hasPlayableAudio(for: meeting, resolve: { _ in directory }))
    }

    @Test func onlyTheChannelThatWroteAFileIsOffered() throws {
        let directory = try makeMeetingDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appending(path: "them.caf"))

        let meeting = Meeting(title: "Standup")
        meeting.audioDirectory = "Meetings/whatever"

        let urls = MeetingAudioPlayback.channelFileURLs(for: meeting, resolve: { _ in directory })
        #expect(urls == [directory.appending(path: "them.caf")])
        #expect(MeetingAudioPlayback.hasPlayableAudio(for: meeting, resolve: { _ in directory }))
    }

    @Test func bothChannelsComeBackMeFirst() throws {
        let directory = try makeMeetingDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Written them-then-me, so passing came from sort order, not write order.
        try Data().write(to: directory.appending(path: "them.caf"))
        try Data().write(to: directory.appending(path: "me.caf"))

        let meeting = Meeting(title: "Standup")
        meeting.audioDirectory = "Meetings/whatever"

        let urls = MeetingAudioPlayback.channelFileURLs(for: meeting, resolve: { _ in directory })
        #expect(urls == [directory.appending(path: "me.caf"), directory.appending(path: "them.caf")])
    }

    /// Interleaved stereo Float32 at 48kHz, matching what `MeetingAudioRecorder`
    /// actually writes — see `AudioRecordingTests.makeTapFormat()`.
    private func makeSilentCAF(at url: URL, seconds: Double) throws {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let format = try #require(AVAudioFormat(streamDescription: &asbd))
        let file = try AVAudioFile(
            forWriting: url, settings: format.settings, commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        try file.write(from: buffer)
    }

    @Test func compositionDurationIsTheLongerChannel() async throws {
        let directory = try makeMeetingDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let me = directory.appending(path: "me.caf")
        let them = directory.appending(path: "them.caf")
        try makeSilentCAF(at: me, seconds: 1)
        try makeSilentCAF(at: them, seconds: 2)

        let composition = try await MeetingAudioPlayback.makeComposition(from: [me, them])
        let duration = try await composition.load(.duration).seconds

        #expect(duration.isApproximatelyEqual(to: 2, tolerance: 0.05))
        #expect(composition.tracks(withMediaType: .audio).count == 2)
    }

    @Test func seekTimePassesAnInRangeSegmentStartThrough() {
        #expect(MeetingAudioPlayback.seekTime(forSegmentStart: 41.5, duration: 300) == 41.5)
    }

    /// A segment can finalize with a start time past the end of the audio —
    /// the shorter channel ran out, or the recorder was cut off before the
    /// transcriber was — and the answer is the end, not a raw overshoot.
    @Test func seekTimeClampsASegmentPastTheAudioToTheEnd() {
        #expect(MeetingAudioPlayback.seekTime(forSegmentStart: 305, duration: 300) == 300)
    }

    @Test func seekTimeNeverGoesNegative() {
        #expect(MeetingAudioPlayback.seekTime(forSegmentStart: -3, duration: 300) == 0)
    }

    /// A player mid-load reports zero or NaN duration; a tap landing in that
    /// window seeks to the start rather than propagating a non-finite time.
    @Test func seekTimeTreatsAnUnloadedDurationAsTheStart() {
        #expect(MeetingAudioPlayback.seekTime(forSegmentStart: 41.5, duration: 0) == 0)
        #expect(MeetingAudioPlayback.seekTime(forSegmentStart: 41.5, duration: .nan) == 0)
        #expect(MeetingAudioPlayback.seekTime(forSegmentStart: .nan, duration: 300) == 0)
    }

    @Test func compositionOverOneChannelStillPlays() async throws {
        let directory = try makeMeetingDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let them = directory.appending(path: "them.caf")
        try makeSilentCAF(at: them, seconds: 1.5)

        let composition = try await MeetingAudioPlayback.makeComposition(from: [them])

        #expect(composition.tracks(withMediaType: .audio).count == 1)
    }
}

extension Double {
    fileprivate func isApproximatelyEqual(to other: Double, tolerance: Double) -> Bool {
        abs(self - other) <= tolerance
    }
}
