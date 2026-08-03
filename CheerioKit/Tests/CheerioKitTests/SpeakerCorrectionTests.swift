import AVFoundation
import Foundation
import Testing
@testable import CheerioKit

@Suite struct SpeakerCorrectionTests {
    /// The failure this whole feature exists for: the diarizer split one person into
    /// "Glen" and "Speaker 3" on the same recording.
    private func splitSpeakerMeeting() -> Meeting {
        let meeting = Meeting(title: "Office")
        let segments = [
            ("Jackson", 17.5, 19.0),
            ("Glen", 19.3, 22.1),
            ("Speaker 3", 21.8, 24.0),
        ].map { label, start, end -> TranscriptSegment in
            let segment = TranscriptSegment(channel: .me, text: label, startTime: start, endTime: end)
            segment.speakerLabel = label
            return segment
        }
        meeting.segments = segments
        return meeting
    }

    @Test func summariesGroupByLabelMostTalkativeFirst() {
        let summaries = splitSpeakerMeeting().speakerSummaries
        #expect(summaries.map(\.label) == ["Glen", "Speaker 3", "Jackson"])
        #expect(summaries.map(\.lineCount) == [1, 1, 1])
        #expect(summaries.allSatisfy { $0.channel == .me })
        #expect(summaries.allSatisfy { !$0.isManual })
    }

    @Test func mergingASplitSpeakerRelabelsEveryLine() {
        let meeting = splitSpeakerMeeting()
        #expect(meeting.relabelSpeaker("Speaker 3", to: "Glen") == 1)

        let summaries = meeting.speakerSummaries
        #expect(summaries.map(\.label) == ["Glen", "Jackson"])
        // Only the corrected line is marked manual; Glen's original stays the model's.
        #expect(meeting.segments.filter(\.isSpeakerLabelManual).count == 1)
        #expect(summaries.first { $0.label == "Glen" }?.isManual == false)
    }

    @Test func resettingASpeakerFallsBackToTheChannelAndDropsTheManualFlag() {
        let meeting = splitSpeakerMeeting()
        meeting.relabelSpeaker("Speaker 3", to: nil)

        // Back to the capture channel, and handed back to the diarizer.
        #expect(meeting.speakerSummaries.contains { $0.label == "Me" })
        #expect(meeting.segments.allSatisfy { !$0.isSpeakerLabelManual })
    }

    @Test func unlabelledMeetingsStillListTheirChannelSpeakers() {
        // A meeting recorded before diarization ran must still be correctable.
        let meeting = Meeting(title: "Old")
        meeting.segments = [
            TranscriptSegment(channel: .me, text: "hi", startTime: 0, endTime: 2),
            TranscriptSegment(channel: .them, text: "hello", startTime: 2, endTime: 3),
        ]
        #expect(meeting.speakerSummaries.map(\.label) == ["Me", "Them"])
        #expect(meeting.relabelSpeaker("Me", to: "Jackson") == 1)
        #expect(meeting.speakerSummaries.map(\.label) == ["Jackson", "Them"])
    }

    @Test func rangesCoverOnlyTheRequestedSpeakerAndChannel() {
        let meeting = splitSpeakerMeeting()
        let ranges = meeting.ranges(forSpeaker: "Glen", channel: .me)
        #expect(ranges == [AudioExcerpt.Range(start: 19.3, end: 22.1)])
        #expect(meeting.ranges(forSpeaker: "Glen", channel: .them).isEmpty)
    }

    @Test func mergingRangesCombinesOverlapsAndDropsEmpties() {
        let merged = AudioExcerpt.merging([
            .init(start: 5, end: 6),
            .init(start: 0, end: 2),
            .init(start: 1.5, end: 3),
            .init(start: 4, end: 4),
        ])
        #expect(merged == [.init(start: 0, end: 3), .init(start: 5, end: 6)])
    }

    @Test func excerptWritesOnlyTheRequestedSeconds() throws {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "excerpt-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let source = directory.appending(path: "source.caf")
        let input = try AVAudioFile(forWriting: source, settings: format.settings)
        // 10 seconds of silence is enough to excerpt from.
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480_000)!
        buffer.frameLength = 480_000
        try input.write(from: buffer)

        let destination = directory.appending(path: "excerpt.caf")
        let written = try AudioExcerpt.write(
            [.init(start: 1, end: 3), .init(start: 5, end: 6)],
            from: source,
            to: destination
        )
        #expect(abs(written - 3) < 0.01)

        // And the file on disk really is that long.
        let output = try AVAudioFile(forReading: destination)
        #expect(abs(Double(output.length) / output.processingFormat.sampleRate - 3) < 0.01)
    }

    @Test func excerptRangesPastTheEndAreTruncatedNotFatal() throws {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "excerpt-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let source = directory.appending(path: "source.caf")
        let input = try AVAudioFile(forWriting: source, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000)!
        buffer.frameLength = 96_000
        try input.write(from: buffer)

        // Transcript timings can run past the recording; clamp rather than fail.
        let written = try AudioExcerpt.write(
            [.init(start: 1, end: 30)],
            from: source,
            to: directory.appending(path: "excerpt.caf")
        )
        #expect(abs(written - 1) < 0.01)

        // But nothing usable at all is an error worth surfacing.
        #expect(throws: AudioExcerpt.ExcerptError.self) {
            try AudioExcerpt.write(
                [.init(start: 50, end: 60)],
                from: source,
                to: directory.appending(path: "empty.caf")
            )
        }
    }
}
