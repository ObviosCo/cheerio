import Foundation
import Testing

@testable import CheerioKit

@Suite struct SpeakerAttributionTests {
    private let turns = [
        SpeakerTurn(label: "Jackson", startTime: 0, endTime: 5),
        SpeakerTurn(label: "Speaker 2", startTime: 4, endTime: 10),
        SpeakerTurn(label: "Speaker 3", startTime: 12, endTime: 14),
    ]

    @Test func picksTheOnlyOverlappingTurn() {
        #expect(SpeakerAttribution.dominantLabel(start: 0.5, end: 2, turns: turns) == "Jackson")
        #expect(SpeakerAttribution.dominantLabel(start: 6, end: 9, turns: turns) == "Speaker 2")
    }

    @Test func picksTheDominantTurnWhenSpeechOverlaps() {
        // 4.0–4.5 is Jackson, 4.5–8.0 is Speaker 2 — the longer overlap wins.
        #expect(SpeakerAttribution.dominantLabel(start: 4, end: 8, turns: turns) == "Speaker 2")
        // Flip the window so Jackson dominates instead.
        #expect(SpeakerAttribution.dominantLabel(start: 1, end: 4.5, turns: turns) == "Jackson")
    }

    @Test func breaksExactTiesAlphabetically() {
        // Equal overlap has no better answer, so pin the tie-break: without one the
        // winner comes back in dictionary order and can differ between runs.
        let tied = [
            SpeakerTurn(label: "Zoe", startTime: 0, endTime: 2),
            SpeakerTurn(label: "Adam", startTime: 2, endTime: 4),
        ]
        #expect(SpeakerAttribution.dominantLabel(start: 0, end: 4, turns: tied) == "Adam")
        #expect(SpeakerAttribution.dominantLabel(start: 0, end: 4, turns: tied.reversed()) == "Adam")
    }

    @Test func returnsNilWhenNothingOverlaps() {
        #expect(SpeakerAttribution.dominantLabel(start: 10.5, end: 11.5, turns: turns) == nil)
        #expect(SpeakerAttribution.dominantLabel(start: 20, end: 30, turns: turns) == nil)
    }

    @Test func zeroLengthWindowDoesNotMatch() {
        // A transcript segment with identical start/end has no overlap to measure.
        #expect(SpeakerAttribution.dominantLabel(start: 3, end: 3, turns: turns) == nil)
    }

    /// An all-remote call's mic track holds one unprimed voice — yours. Labelling it
    /// "Speaker 1" is worse than leaving it "Me", because the summarizer is instructed
    /// not to assume a numbered speaker is the user.
    @Test func aLoneUnnamedVoiceAddsNothingOverTheChannelName() {
        #expect(
            !SpeakerAttribution.addsInformation([
                SpeakerTurn(label: "Speaker 1", startTime: 0, endTime: 30)
            ]))
        // Several unnamed voices is real information: three people in a room.
        #expect(
            SpeakerAttribution.addsInformation([
                SpeakerTurn(label: "Speaker 1", startTime: 0, endTime: 5),
                SpeakerTurn(label: "Speaker 2", startTime: 5, endTime: 9),
            ]))
        // And one *named* voice is an actual identification, so it stays.
        #expect(
            SpeakerAttribution.addsInformation([
                SpeakerTurn(label: "Jackson", startTime: 0, endTime: 30)
            ]))
        #expect(!SpeakerAttribution.addsInformation([]))
    }

    @Test func emptyTurnsYieldNoLabel() {
        #expect(SpeakerAttribution.dominantLabel(start: 0, end: 5, turns: []) == nil)
    }

    /// An enrolled voice must come back under its own name, not "Speaker N".
    /// Opt-in, needs the model plus a reference recording of one person:
    ///   CHEERIO_SORTFORMER_MODEL=… CHEERIO_TEST_AUDIO=… \
    ///   CHEERIO_ENROLL_AUDIO=… CHEERIO_ENROLL_NAME=Jackson swift test
    @Test func enrolledSpeakerIsNamed() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["CHEERIO_SORTFORMER_MODEL"],
            let audioPath = environment["CHEERIO_TEST_AUDIO"],
            let enrollPath = environment["CHEERIO_ENROLL_AUDIO"],
            let enrollName = environment["CHEERIO_ENROLL_NAME"]
        else { return }

        let service = SpeakerAttributionService(modelURL: URL(fileURLWithPath: modelPath))
        let turns = try await service.attribute(
            audioFile: URL(fileURLWithPath: audioPath),
            enrolling: [
                SpeakerEnrollment(audioFile: URL(fileURLWithPath: enrollPath), name: enrollName)
            ]
        )

        #expect(!turns.isEmpty)
        let labels = Set(turns.map(\.label))
        #expect(
            labels.contains(enrollName),
            "enrolled voice was not named; got \(labels.sorted())"
        )
    }

    /// End-to-end against a real recording. Needs the bundled Sortformer model,
    /// so it's opt-in:
    ///   CHEERIO_SORTFORMER_MODEL=/path/to/Sortformer_v2.1.mlmodelc \
    ///   CHEERIO_TEST_AUDIO=/path/to/recording.wav swift test
    @Test func diarizesRealRecording() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["CHEERIO_SORTFORMER_MODEL"],
            let audioPath = environment["CHEERIO_TEST_AUDIO"]
        else { return }

        let service = SpeakerAttributionService(modelURL: URL(fileURLWithPath: modelPath))
        let turns = try await service.attribute(audioFile: URL(fileURLWithPath: audioPath))

        // How many speakers is a property of whatever audio the caller pointed at,
        // so only the invariants are asserted here.
        #expect(!turns.isEmpty)
        #expect(turns == turns.sorted { $0.startTime < $1.startTime })
        #expect(turns.allSatisfy { $0.endTime > $0.startTime })
    }
}
