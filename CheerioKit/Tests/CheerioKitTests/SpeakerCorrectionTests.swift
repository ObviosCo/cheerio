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

    /// Look a speaker up the way the UI does, by the row the user clicked.
    private func summary(in meeting: Meeting, _ label: String, channel: SpeakerChannel? = nil) -> SpeakerSummary {
        let matches = meeting.speakerSummaries.filter {
            $0.label == label && (channel == nil || $0.scopedChannel == channel)
        }
        precondition(matches.count == 1, "expected exactly one “\(label)” speaker, found \(matches.count)")
        return matches[0]
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
        #expect(meeting.relabelSpeaker(summary(in: meeting, "Speaker 3"), to: "Glen") == 1)

        let summaries = meeting.speakerSummaries
        #expect(summaries.map(\.label) == ["Glen", "Jackson"])
        // Only the corrected line is marked manual; Glen's original stays the model's.
        #expect(meeting.segments.filter(\.isSpeakerLabelManual).count == 1)
        #expect(summaries.first { $0.label == "Glen" }?.isManual == false)
    }

    @Test func resettingASpeakerFallsBackToTheChannelAndDropsTheManualFlag() {
        let meeting = splitSpeakerMeeting()
        meeting.relabelSpeaker(summary(in: meeting, "Speaker 3"), to: nil)

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
        #expect(meeting.relabelSpeaker(summary(in: meeting, "Me"), to: "Jackson") == 1)
        #expect(meeting.speakerSummaries.map(\.label) == ["Jackson", "Them"])
    }

    @Test func confirmSpeakerFlipsOnlyThatSpeakersModelMatchedLines() {
        let meeting = splitSpeakerMeeting()
        let glen = summary(in: meeting, "Glen")
        #expect(meeting.confirmSpeaker(glen) == 1)

        #expect(meeting.segments.first { $0.text == "Glen" }?.isSpeakerLabelManual == true)
        // "and only that speaker's" — Jackson and Speaker 3 are untouched.
        #expect(meeting.segments.filter { $0.text != "Glen" }.allSatisfy { !$0.isSpeakerLabelManual })

        // The panel's provenance summary is derived from `isManual`; it must flip too.
        #expect(meeting.speakerSummaries.first { $0.label == "Glen" }?.isManual == true)
        #expect(meeting.speakerSummaries.first { $0.label == "Speaker 3" }?.isManual == false)
    }

    @Test func confirmSpeakerIsIdempotent() {
        let meeting = splitSpeakerMeeting()
        #expect(meeting.confirmSpeaker(summary(in: meeting, "Glen")) == 1)
        // Re-reading the summary after the first confirm, the way the panel would
        // after a save — nothing left to flip, so nothing reports as changed.
        #expect(meeting.confirmSpeaker(summary(in: meeting, "Glen")) == 0)
        #expect(meeting.segments.first { $0.text == "Glen" }?.isSpeakerLabelManual == true)
    }

    /// A speaker can carry both a hand-corrected line and a still-model-matched one —
    /// the single corrected line from a `relabelSpeaker` merge, say. Confirming must
    /// leave the already-manual line alone and only settle the rest.
    @Test func confirmSpeakerHandlesMixedManualAndModelLines() {
        let meeting = Meeting(title: "Standup")
        let modelLine = TranscriptSegment(channel: .me, text: "model", startTime: 0, endTime: 1)
        modelLine.speakerLabel = "Jackson"
        let manualLine = TranscriptSegment(channel: .me, text: "manual", startTime: 1, endTime: 2)
        manualLine.assignSpeaker("Jackson")
        meeting.segments = [modelLine, manualLine]

        let jackson = summary(in: meeting, "Jackson")
        #expect(jackson.isManual == false)

        #expect(meeting.confirmSpeaker(jackson) == 1)
        #expect(modelLine.isSpeakerLabelManual)
        #expect(manualLine.isSpeakerLabelManual)
        #expect(meeting.speakerSummaries.first { $0.label == "Jackson" }?.isManual == true)
    }

    /// The guarantee a rename already gets: re-identification only ever overwrites
    /// segments that aren't ``TranscriptSegment/isSpeakerLabelManual`` (see the guard
    /// in `SpeakerLabeling.label`, in the app target). Confirming sets exactly that
    /// bit, so it must survive a re-run the same way a hand rename does — mirroring
    /// that guard here since the surrounding diarization pass isn't something
    /// CheerioKit can run without the bundled model.
    @Test func confirmedLinesSurviveReAttribution() {
        let meeting = splitSpeakerMeeting()
        #expect(meeting.confirmSpeaker(summary(in: meeting, "Glen")) == 1)

        for segment in meeting.segments where !segment.isSpeakerLabelManual {
            segment.speakerLabel = "Speaker 9"
        }

        #expect(meeting.segments.first { $0.text == "Glen" }?.speakerLabel == "Glen")
        #expect(meeting.speakerSummaries.first { $0.label == "Glen" }?.isManual == true)
    }

    @Test func rangesCoverOnlyTheRequestedSpeakerAndChannel() {
        let meeting = splitSpeakerMeeting()
        let ranges = meeting.ranges(for: summary(in: meeting, "Glen"))
        #expect(ranges == [AudioExcerpt.Range(start: 19.3, end: 22.1)])
    }

    /// The two channels are diarized independently, so their generated numbering is
    /// independent too: the mic's "Speaker 1" and the system tap's are different
    /// people. Grouping them together fused two strangers into one row and renamed
    /// both at once.
    @Test func generatedLabelsDoNotMergeAcrossChannels() {
        let meeting = Meeting(title: "Hybrid call")
        meeting.segments = [
            ("Speaker 1", SpeakerChannel.me, 0.0, 4.0),
            ("Speaker 1", .them, 5.0, 6.0),
        ].map { label, channel, start, end in
            let segment = TranscriptSegment(channel: channel, text: label, startTime: start, endTime: end)
            segment.speakerLabel = label
            return segment
        }

        let summaries = meeting.speakerSummaries
        #expect(summaries.count == 2)
        #expect(summaries.map(\.scopedChannel) == [.me, .them])
        // Distinguishable in the UI, and distinct as far as SwiftUI identity goes.
        #expect(Set(summaries.map(\.id)).count == 2)
        #expect(summaries.map(\.displayName) == ["Speaker 1 · in room", "Speaker 1 · remote"])

        // Renaming one must not touch the other.
        #expect(meeting.relabelSpeaker(summary(in: meeting, "Speaker 1", channel: .me), to: "Glen") == 1)
        #expect(meeting.speakerSummaries.map(\.label).sorted() == ["Glen", "Speaker 1"])

        // And an excerpt for one must not pull in the other's audio.
        let remote = summary(in: meeting, "Speaker 1", channel: .them)
        #expect(meeting.ranges(for: remote) == [AudioExcerpt.Range(start: 5, end: 6)])
    }

    /// An enrolled name is the same person whichever channel they turn up on — someone
    /// in the room whose voice also comes down the call feed shouldn't split in two.
    @Test func realNamesStillMergeAcrossChannels() {
        let meeting = Meeting(title: "Hybrid call")
        meeting.segments = [
            ("Glen", SpeakerChannel.me, 0.0, 4.0),
            ("Glen", .them, 5.0, 6.0),
        ].map { label, channel, start, end in
            let segment = TranscriptSegment(channel: channel, text: label, startTime: start, endTime: end)
            segment.speakerLabel = label
            return segment
        }

        let summaries = meeting.speakerSummaries
        #expect(summaries.count == 1)
        #expect(summaries[0].scopedChannel == nil)
        #expect(summaries[0].displayName == "Glen")
        // Most of his audio is on the mic, so that's the recording to excerpt from.
        #expect(summaries[0].channel == .me)
    }

    @Test func onlyNumberedSpeakerLabelsCountAsGenerated() {
        #expect(TranscriptSegment.isDiarizerGeneratedLabel("Speaker 1"))
        #expect(TranscriptSegment.isDiarizerGeneratedLabel("Speaker 12"))
        // A real person who happens to be named this way must not be channel-scoped.
        #expect(!TranscriptSegment.isDiarizerGeneratedLabel("Speaker Pelosi"))
        #expect(!TranscriptSegment.isDiarizerGeneratedLabel("Speaker "))
        #expect(!TranscriptSegment.isDiarizerGeneratedLabel("Glen"))
        #expect(!TranscriptSegment.isDiarizerGeneratedLabel(nil))
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
        let orphan = directory.appending(path: "empty.caf")
        #expect(throws: AudioExcerpt.ExcerptError.self) {
            try AudioExcerpt.write([.init(start: 50, end: 60)], from: source, to: orphan)
        }
        // And the half-made file must not survive the failure: callers name samples by
        // UUID and only persist the path on success, so anything left here is garbage
        // nobody can trace back.
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }
}
