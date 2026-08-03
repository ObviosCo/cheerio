import Foundation
import Testing
@testable import CheerioKit

@Suite struct ParticipantRosterTests {
    private let limit = 4

    private func speaker(_ name: String, isMe: Bool = false) -> EnrolledSpeaker {
        let speaker = EnrolledSpeaker(name: name, audioPath: "Speakers/\(name).caf", duration: 30)
        speaker.isMe = isMe
        return speaker
    }

    /// More voices saved than the diarizer can resolve — the situation the roster exists for.
    private var enrolled: [EnrolledSpeaker] {
        [
            speaker("Jackson", isMe: true),
            speaker("Carter"),
            speaker("Glen"),
            speaker("Sarah"),
            speaker("Whitney"),
        ]
    }

    @Test func onlyTheChosenVoicesArePrimed() {
        let meeting = Meeting(title: "Standup")
        meeting.participantNames = ["Jackson", "Sarah", "Whitney"]

        let (chosen, dropped) = meeting.participants(from: enrolled, limit: limit)
        #expect(chosen.map(\.name) == ["Jackson", "Sarah", "Whitney"])
        #expect(dropped.isEmpty)
    }

    @Test func anEmptyRosterPrimesNobody() {
        // All-remote: the mic/system split already separates you from them, so priming
        // anyone just burns slots.
        let meeting = Meeting(title: "Remote call")
        meeting.participantNames = []

        let (chosen, dropped) = meeting.participants(from: enrolled, limit: limit)
        #expect(chosen.isEmpty)
        #expect(dropped.isEmpty)
    }

    @Test func anUnsetRosterFallsBackToEveryoneEnrolled() {
        // Meetings recorded before rosters existed must keep working.
        let meeting = Meeting(title: "Old")
        #expect(meeting.participantNames == nil)

        let (chosen, _) = meeting.participants(from: enrolled, limit: limit)
        #expect(chosen.count == limit)
    }

    @Test func theCapReportsWhoItLeftOutInsteadOfTruncatingSilently() {
        let meeting = Meeting(title: "Crowded")
        meeting.participantNames = ["Carter", "Glen", "Sarah", "Whitney", "Jackson"]

        let (chosen, dropped) = meeting.participants(from: enrolled, limit: limit)
        #expect(chosen.count == limit)
        #expect(dropped.map(\.name) == ["Whitney"])
        // Nobody is both used and dropped.
        #expect(Set(chosen.map(\.name)).isDisjoint(with: dropped.map(\.name)))
    }

    @Test func yourOwnVoiceSurvivesTheCap() {
        // "I'd always be there" — so if the cap bites, it must not bite you.
        let meeting = Meeting(title: "Crowded")
        meeting.participantNames = ["Carter", "Glen", "Sarah", "Whitney", "Jackson"]

        let (chosen, _) = meeting.participants(from: enrolled, limit: limit)
        #expect(chosen.first?.name == "Jackson")
        #expect(chosen.contains { $0.isMe })
    }

    @Test func nonMeOrderFollowsEnrollmentOrder() {
        // The partition must not scramble everyone else — `sorted` isn't stable.
        let meeting = Meeting(title: "Standup")
        meeting.participantNames = ["Whitney", "Sarah", "Carter", "Jackson"]

        let (chosen, _) = meeting.participants(from: enrolled, limit: limit)
        #expect(chosen.map(\.name) == ["Jackson", "Carter", "Sarah", "Whitney"])
    }

    @Test func namesWithNoMatchingEnrollmentAreIgnored() {
        // A removed speaker leaves their name behind in old rosters.
        let meeting = Meeting(title: "Standup")
        meeting.participantNames = ["Jackson", "Someone who left"]

        let (chosen, dropped) = meeting.participants(from: enrolled, limit: limit)
        #expect(chosen.map(\.name) == ["Jackson"])
        #expect(dropped.isEmpty)
    }
}
