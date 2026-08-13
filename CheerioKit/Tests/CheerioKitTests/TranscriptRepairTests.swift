import AVFoundation
import Foundation
import SwiftData
import Testing

@testable import CheerioKit

/// The decisions a re-transcription pass turns on (issue #14), none of which need a
/// speech model: which channels can be repaired, which ones look like they should
/// be, and what happens to lines already in the store when a fresh pass lands.
@Suite struct TranscriptRepairTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Meeting.self, TranscriptSegment.self, EnrolledSpeaker.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    /// A meeting with audio "on disk" at `directory`, whose `audioDirectory` any
    /// injected `resolve` maps straight back to it.
    private func makeMeeting(audioDirectory: String? = "Meetings/apollo") -> Meeting {
        let meeting = Meeting(title: "Apollo project overhaul")
        meeting.audioDirectory = audioDirectory
        meeting.endedAt = meeting.startedAt.addingTimeInterval(3_480)
        return meeting
    }

    private func segment(
        _ channel: SpeakerChannel,
        _ text: String,
        _ start: TimeInterval,
        _ end: TimeInterval,
        manual: Bool = false,
        confirmed: Bool = false
    ) -> TranscriptSegment {
        let segment = TranscriptSegment(channel: channel, text: text, startTime: start, endTime: end)
        segment.isSpeakerLabelManual = manual
        segment.isSpeakerLabelConfirmed = confirmed
        if manual || confirmed { segment.speakerLabel = "Jackson" }
        return segment
    }

    private func line(_ channel: SpeakerChannel, _ text: String, _ start: TimeInterval, _ end: TimeInterval)
        -> TranscriptionUpdate
    {
        TranscriptionUpdate(channel: channel, text: text, isFinal: true, startTime: start, endTime: end)
    }

    /// A directory with the named channels' CAFs in it, plus a `resolve` that points
    /// any relative path at it — so nothing here touches the real Application
    /// Support container.
    private func makeAudioDirectory(
        channels: [SpeakerChannel],
        peakAmplitude: Float = 0.5,
        channelCount: UInt32 = 1,
        sampleRate: Double = 48_000,
        seconds: Double = 1
    ) throws -> (directory: URL, resolve: (String) throws -> URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "transcript-repair-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for channel in channels {
            try writeCAF(
                to: directory.appending(path: "\(channel.rawValue).caf"),
                peakAmplitude: peakAmplitude,
                channelCount: channelCount,
                sampleRate: sampleRate,
                seconds: seconds
            )
        }
        return (directory, { _ in directory })
    }

    private func writeCAF(
        to url: URL,
        peakAmplitude: Float,
        channelCount: UInt32,
        sampleRate: Double,
        seconds: Double
    ) throws {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channelCount, interleaved: false))
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData)
        for channel in 0..<Int(channelCount) {
            for frame in 0..<Int(frames) {
                samples[channel][frame] = peakAmplitude * sin(Float(frame) * 0.05)
            }
        }
        let file = try AVAudioFile(
            forWriting: url, settings: format.settings, commonFormat: format.commonFormat,
            interleaved: format.isInterleaved)
        try file.write(from: buffer)
    }

    // MARK: - What can be repaired

    @Test func probesFindEveryChannelWithAudioOnDisk() throws {
        let audio = try makeAudioDirectory(channels: [.me, .them])
        defer { try? FileManager.default.removeItem(at: audio.directory) }

        let meeting = makeMeeting()
        meeting.segments = [segment(.them, "Their side made it", 1, 2)]

        let probes = TranscriptRepair.probes(in: meeting, resolve: audio.resolve)
        #expect(probes.map(\.channel) == [.me, .them])
        // Apollo's shape exactly: healthy audio on both channels, transcript on one.
        #expect(probes.map(\.segmentCount) == [0, 1])
    }

    @Test func probesAreEmptyOnceRetentionHasPurgedTheAudio() throws {
        let audio = try makeAudioDirectory(channels: [.me, .them])
        defer { try? FileManager.default.removeItem(at: audio.directory) }

        #expect(TranscriptRepair.probes(in: makeMeeting(audioDirectory: nil), resolve: audio.resolve).isEmpty)
    }

    @Test func refusesAChannelWhoseAudioIsGone() throws {
        let audio = try makeAudioDirectory(channels: [.them])
        defer { try? FileManager.default.removeItem(at: audio.directory) }
        let meeting = makeMeeting()

        // The channel that never wrote a file, and the whole meeting whose directory
        // retention cleared, are the same refusal — both mean "there is nothing to
        // read", which is all a person needs to be told.
        #expect(throws: TranscriptRepair.Refusal.audioUnavailable) {
            _ = try TranscriptRepair.audioFile(for: .me, in: meeting, isBusy: false, resolve: audio.resolve)
        }
        #expect(throws: TranscriptRepair.Refusal.audioUnavailable) {
            _ = try TranscriptRepair.audioFile(
                for: .them, in: makeMeeting(audioDirectory: nil), isBusy: false, resolve: audio.resolve)
        }
        #expect(
            try TranscriptRepair.audioFile(for: .them, in: meeting, isBusy: false, resolve: audio.resolve)
                == audio.directory.appending(path: "them.caf"))
    }

    @Test func refusesWhileSomethingElseIsWorkingOnTheMeeting() throws {
        let audio = try makeAudioDirectory(channels: [.me])
        defer { try? FileManager.default.removeItem(at: audio.directory) }

        // Busy loses to nothing: it's checked before the file, so a purged meeting
        // that's also mid-pipeline reports the state that will pass on its own.
        #expect(throws: TranscriptRepair.Refusal.busy) {
            _ = try TranscriptRepair.audioFile(
                for: .me, in: makeMeeting(), isBusy: true, resolve: audio.resolve)
        }
    }

    // MARK: - What looks like it wants repairing

    @Test func aChannelWithAudioAndNoTranscriptIsTheOneWorthPrompting() throws {
        let audio = try makeAudioDirectory(channels: [.me], peakAmplitude: 0.5)
        defer { try? FileManager.default.removeItem(at: audio.directory) }

        let probe = TranscriptRepair.ChannelProbe(
            channel: .me, audioFile: audio.directory.appending(path: "me.caf"), segmentCount: 0)
        let coverage = try #require(try TranscriptRepair.coverage(for: probe))
        #expect(coverage.verdict == .signalWithoutTranscript)
        #expect(coverage.format == CapturedAudioFormat(channelCount: 1, sampleRate: 48_000))
        #expect(coverage.diagnosis != nil)
    }

    /// A channel that recorded silence is a permission or device failure, already
    /// diagnosed where it happened — re-transcribing digital silence would produce
    /// nothing and waste minutes doing it.
    @Test func aSilentChannelIsNotOfferedAsRepairable() async throws {
        let audio = try makeAudioDirectory(channels: [.me], peakAmplitude: 0)
        defer { try? FileManager.default.removeItem(at: audio.directory) }

        let probe = TranscriptRepair.ChannelProbe(
            channel: .me, audioFile: audio.directory.appending(path: "me.caf"), segmentCount: 0)
        #expect(try TranscriptRepair.coverage(for: probe)?.verdict == .silentChannel)
        #expect(await TranscriptRepair.channelsWantingRepair([probe]).isEmpty)
    }

    /// The reason this is safe to run every time a meeting is opened: a channel that
    /// produced text can't be the bug, so no audio is read to say so. Pointed at a
    /// file that doesn't exist, it still answers.
    @Test func aChannelThatProducedTextIsAnsweredWithoutReadingItsAudio() throws {
        let probe = TranscriptRepair.ChannelProbe(
            channel: .me,
            audioFile: URL(filePath: "/nonexistent/me.caf"),
            segmentCount: 12
        )
        #expect(try TranscriptRepair.coverage(for: probe) == nil)
    }

    // MARK: - Merging a fresh pass in

    @Test func replacesOnlyTheChosenChannel() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let meeting = makeMeeting()
        let theirs = segment(.them, "Their side made it", 1, 2)
        let mine = segment(.me, "half a word", 3, 4)
        meeting.segments = [theirs, mine]
        context.insert(meeting)
        try context.save()

        let outcome = try TranscriptRepair.replace(
            channel: .me,
            in: meeting,
            with: [line(.me, "Ship the fix on Tuesday", 3, 5), line(.me, "Then tell Carter", 6, 7)],
            context: context
        )

        #expect(outcome == TranscriptRepair.Outcome(inserted: 2, replaced: 1, kept: 0, skipped: 0))
        let mineNow = meeting.segments.filter { $0.channel == .me }.sorted { $0.startTime < $1.startTime }
        #expect(mineNow.map(\.text) == ["Ship the fix on Tuesday", "Then tell Carter"])
        #expect(meeting.segments.filter { $0.channel == .them }.map(\.text) == ["Their side made it"])
    }

    /// The rule #170 established for bleed marks, applied here: a renamed or
    /// confirmed line is testimony and outranks a machine pass.
    @Test func humanSettledLinesSurviveARePass() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let meeting = makeMeeting()
        let renamed = segment(.me, "Carter said it, not me", 10, 12, manual: true)
        let confirmed = segment(.me, "That one was right", 30, 32, confirmed: true)
        let machine = segment(.me, "garbled", 50, 52)
        meeting.segments = [renamed, confirmed, machine]
        context.insert(meeting)
        try context.save()

        let outcome = try TranscriptRepair.replace(
            channel: .me,
            in: meeting,
            with: [
                // Overlaps the renamed line: dropped, because those seconds already
                // have a line a person spoke for, and two lines for one utterance is
                // worse than one the re-pass didn't get to improve.
                line(.me, "Carter said it not me", 9.5, 12.5),
                // Overlaps the confirmed line: same.
                line(.me, "that one was right", 31, 33),
                // Free ground, and where the machine line was: goes in.
                line(.me, "Ship the fix on Tuesday", 50, 53),
            ],
            context: context
        )

        #expect(outcome == TranscriptRepair.Outcome(inserted: 1, replaced: 1, kept: 2, skipped: 2))
        let texts = meeting.segments.filter { $0.channel == .me }
            .sorted { $0.startTime < $1.startTime }
            .map(\.text)
        #expect(texts == ["Carter said it, not me", "That one was right", "Ship the fix on Tuesday"])
        #expect(renamed.isSpeakerLabelManual)
        #expect(confirmed.isSpeakerLabelConfirmed)
        #expect(meeting.segments.allSatisfy { $0.speakerLabel == nil || $0.speakerLabel == "Jackson" })
    }

    /// Lines that only touch at an endpoint — the ordinary shape of consecutive
    /// segments — aren't overlapping, or a settled line would swallow whatever came
    /// immediately before and after it.
    @Test func aFreshLineAbuttingSettledTestimonyStillGoesIn() {
        let spans = [TranscriptRepair.Span(start: 10, end: 12)]
        let candidates = [
            line(.me, "before", 8, 10),
            line(.me, "after", 12, 14),
            line(.me, "during", 11, 11.5),
        ]
        #expect(TranscriptRepair.insertable(candidates, keeping: spans).map(\.text) == ["before", "after"])
    }

    /// Volatile results animate a live transcript and mean nothing here; a blank
    /// line means nothing anywhere.
    @Test func volatileAndBlankLinesAreNotStored() {
        let lines = [
            TranscriptionUpdate(channel: .me, text: "still forming", isFinal: false, startTime: 0, endTime: 1),
            TranscriptionUpdate(channel: .me, text: "   ", isFinal: true, startTime: 1, endTime: 2),
            TranscriptionUpdate(channel: .them, text: "other channel", isFinal: true, startTime: 2, endTime: 3),
            TranscriptionUpdate(channel: .me, text: "keep me", isFinal: true, startTime: 3, endTime: 4),
        ]
        #expect(TranscriptRepair.usableLines(lines, for: .me).map(\.text) == ["keep me"])
    }

    /// A pass that comes back empty over audio that transcribed once is a failed
    /// pass, not a silent recording — deleting the lines on that evidence would make
    /// a recovery feature a way to lose the half that worked.
    @Test func anEmptyPassLeavesAnExistingTranscriptAlone() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let meeting = makeMeeting()
        meeting.segments = [segment(.me, "half a word", 3, 4)]
        context.insert(meeting)
        try context.save()

        #expect(throws: TranscriptRepair.Refusal.nothingTranscribed) {
            _ = try TranscriptRepair.replace(channel: .me, in: meeting, with: [], context: context)
        }
        #expect(meeting.segments.map(\.text) == ["half a word"])
    }

    /// The honest empty case: nothing was there, nothing came back, nothing is
    /// claimed.
    @Test func anEmptyPassOverAnEmptyChannelIsAllowed() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let meeting = makeMeeting()
        meeting.segments = [segment(.them, "Their side made it", 1, 2)]
        context.insert(meeting)
        try context.save()

        let outcome = try TranscriptRepair.replace(channel: .me, in: meeting, with: [], context: context)
        #expect(outcome == TranscriptRepair.Outcome(inserted: 0, replaced: 0, kept: 0, skipped: 0))
        #expect(meeting.segments.count == 1)
    }
}
