import Foundation
import Testing

@testable import CheerioKit

/// `SpeakerSlotAssigner` is the one piece of the app-theme vocabulary that has to be
/// persisted rather than recomputed: colour is part of a speaker's identity, so a
/// relaunch — or a rename, or a fresh diarization pass — must never hand someone a
/// different slot than the one they were already reading against. These tests pin
/// that contract independent of any view or store.
@Suite struct SpeakerSlotAssignerTests {
    @Test func assignsInNumericOrderAsSpeakersFirstAppear() {
        var assigner = SpeakerSlotAssigner()
        #expect(assigner.slot(for: "a") == .slot(1))
        #expect(assigner.slot(for: "b") == .slot(2))
        #expect(assigner.slot(for: "c") == .slot(3))
    }

    @Test func aSpeakerAlreadyAssignedKeepsTheSameSlotOnLookup() {
        var assigner = SpeakerSlotAssigner()
        let first = assigner.slot(for: "Glen")
        #expect(assigner.slot(for: "Glen") == first)
        #expect(assigner.slot(for: "Glen") == first)
    }

    /// The scenario the whole persistence requirement exists for: a fresh
    /// diarization pass (or any other re-resolution) must add slots for anyone new
    /// without touching what an existing speaker already has — otherwise the colour
    /// under someone mid-read would change for no reason the transcript explains.
    @Test func reResolvingAddsNewSpeakersWithoutReshufflingExistingOnes() {
        var assigner = SpeakerSlotAssigner()
        let glen = assigner.slot(for: "Glen")
        let mary = assigner.slot(for: "Mary")

        // A third speaker shows up on a later pass.
        let newcomer = assigner.slot(for: "Speaker 3")

        #expect(assigner.slot(for: "Glen") == glen)
        #expect(assigner.slot(for: "Mary") == mary)
        #expect(newcomer == .slot(3))
        #expect(Set([glen, mary, newcomer]).count == 3)
    }

    @Test func isYouPinsTheLocalChannelToTheSelfSlotOutsideRotation() {
        var assigner = SpeakerSlotAssigner()
        #expect(assigner.slot(for: "Me", isYou: true) == .you)
        // Pinned regardless of when it resolves relative to everyone else.
        _ = assigner.slot(for: "Guest 1")
        #expect(assigner.slot(for: "Me", isYou: true) == .you)
        // `.you` never consumes a numbered slot — the next new speaker still gets 2.
        #expect(assigner.slot(for: "Guest 2") == .slot(2))
    }

    @Test func capacityExhaustedFallsBackToUnresolvedInsteadOfWrappingOrCrashing() {
        var assigner = SpeakerSlotAssigner()
        for n in 1...SpeakerSlot.capacity {
            #expect(assigner.slot(for: "speaker-\(n)") == .slot(n))
        }
        #expect(assigner.slot(for: "one-too-many") == .unresolved)
        // A ninth speaker on a later pass still falls back — the assigner doesn't
        // retry rotation once it's spent every numbered slot.
        #expect(assigner.slot(for: "also-too-many") == .unresolved)
        // The eight speakers already seated keep their exact slots.
        #expect(assigner.slot(for: "speaker-1") == .slot(1))
        #expect(assigner.slot(for: "speaker-8") == .slot(8))
    }

    /// The persistence contract itself: `Meeting.speakerSlotAssigner` is a plain
    /// `Codable` value, so encoding it (as `Meeting` does via SwiftData) and decoding
    /// it back — simulating a relaunch — must reproduce the exact same assignments,
    /// not just equivalent-looking ones.
    @Test func roundTripsThroughEncodingWithoutLosingOrReorderingAssignments() throws {
        var assigner = SpeakerSlotAssigner()
        _ = assigner.slot(for: "Me", isYou: true)
        _ = assigner.slot(for: "Glen")
        _ = assigner.slot(for: "Speaker 2")

        let data = try JSONEncoder().encode(assigner)
        var decoded = try JSONDecoder().decode(SpeakerSlotAssigner.self, from: data)

        #expect(decoded == assigner)
        #expect(decoded.slot(for: "Me", isYou: true) == .you)
        #expect(decoded.slot(for: "Glen") == assigner.slot(for: "Glen"))
        // And resolution continues from where it left off — a new speaker after the
        // round-trip doesn't collide with one assigned before it.
        let next = decoded.slot(for: "New Speaker")
        #expect(!assigner.assignments.values.contains(next))
    }
}

/// `Meeting.resolveSpeakerSlots(ownerNames:)` is the call site the design handoff
/// describes — "call `slot(for:isYou:)` as speakers resolve, in order" — exercised
/// against real `speakerSummaries`, the same data the transcript rail and the "Who
/// was here" panel render from.
@Suite struct MeetingSpeakerSlotResolutionTests {
    @Test func pinsTheMicChannelToYouAndAssignsGuestsInTalkTimeOrder() {
        let meeting = Meeting(title: "Standup")
        meeting.segments = [
            TranscriptSegment(channel: .me, text: "hi", startTime: 0, endTime: 5),
            TranscriptSegment(channel: .them, text: "hey", startTime: 5, endTime: 8),
        ]

        let assignments = meeting.resolveSpeakerSlots(ownerNames: [])

        #expect(assignments["Me"] == .you)
        #expect(assignments["Them"] == .slot(1))
    }

    /// A real name resolves through the enrolled "me" voice's name, not just the
    /// generic mic-channel fallback — the same `ownerNames` set
    /// `isOwnerAttributed(_:ownerNames:)` and `reconcileActionItems` already use.
    @Test func anEnrolledOwnerNameAlsoPinsToYouOnEitherChannel() {
        let meeting = Meeting(title: "Call")
        meeting.segments = [
            TranscriptSegment(channel: .me, text: "hi", startTime: 0, endTime: 2),
            TranscriptSegment(channel: .them, text: "echo of me", startTime: 2, endTime: 3),
        ]
        meeting.segments[0].speakerLabel = "Jackson"
        meeting.segments[1].speakerLabel = "Jackson"

        let assignments = meeting.resolveSpeakerSlots(ownerNames: ["Jackson"])
        #expect(assignments["Jackson"] == .you)
    }

    /// Re-running resolution — the "re-identify speakers" action — must not move
    /// anyone already slotted, even once new speakers have been added in between.
    @Test func reRunningResolutionAfterNewSpeakersJoinLeavesEarlierSlotsAlone() {
        let meeting = Meeting(title: "Growing call")
        meeting.segments = [
            TranscriptSegment(channel: .me, text: "hi", startTime: 0, endTime: 2)
        ]
        let first = meeting.resolveSpeakerSlots(ownerNames: [])
        #expect(first["Me"] == .you)

        meeting.segments.append(
            TranscriptSegment(channel: .them, text: "hello", startTime: 2, endTime: 4)
        )
        let second = meeting.resolveSpeakerSlots(ownerNames: [])
        #expect(second["Me"] == .you)
        #expect(second["Them"] == .slot(1))

        // A third pass with nothing new changes nothing.
        let third = meeting.resolveSpeakerSlots(ownerNames: [])
        #expect(third == second)
    }

    /// Two unrelated "Speaker 1"s — one per channel — are different people and must
    /// land on different slots, keyed the same way `TranscriptSegment.speakerSlotKey`
    /// and `SpeakerSummary.id` already scope them.
    @Test func channelScopedGeneratedLabelsGetDistinctSlots() {
        let meeting = Meeting(title: "Hybrid call")
        meeting.segments = [
            ("Speaker 1", SpeakerChannel.me, 0.0, 4.0),
            ("Speaker 1", .them, 5.0, 6.0),
        ].map { label, channel, start, end in
            let segment = TranscriptSegment(channel: channel, text: label, startTime: start, endTime: end)
            segment.speakerLabel = label
            return segment
        }

        let assignments = meeting.resolveSpeakerSlots(ownerNames: [])
        #expect(Set(assignments.values).count == 2)

        for segment in meeting.segments {
            #expect(assignments[segment.speakerSlotKey] != nil)
        }
    }
}
