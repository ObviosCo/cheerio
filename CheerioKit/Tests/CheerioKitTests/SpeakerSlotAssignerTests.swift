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

    /// The bug Copilot caught: `.unresolved` used to be stored and then returned
    /// early on every subsequent lookup, so a speaker who was over capacity once
    /// stayed `.unresolved` forever — even after a merge elsewhere freed a
    /// number. `.unresolved` isn't sticky the way `.you` and a numbered slot are;
    /// every lookup retries allocation.
    @Test func unresolvedIsRetryableOnceASlotFreesUpElsewhere() {
        var assigner = SpeakerSlotAssigner()
        for n in 1...SpeakerSlot.capacity {
            _ = assigner.slot(for: "speaker-\(n)")
        }
        #expect(assigner.slot(for: "over-capacity") == .unresolved)

        // A merge elsewhere frees a number — "speaker-1" turns out to be
        // "speaker-2", so "speaker-1"'s slot is abandoned.
        assigner.rename(from: "speaker-1", to: "speaker-2")

        // Looked up again, "over-capacity" actually gets the freed number now,
        // rather than being stuck at whatever got stored last time.
        #expect(assigner.slot(for: "over-capacity") == .slot(1))
    }

    /// Numbered and `.you` assignments stay sticky even though `.unresolved`
    /// doesn't — retrying every lookup would otherwise risk reshuffling someone
    /// who already has a real slot.
    @Test func numberedAndYouAssignmentsStayStickyWhileUnresolvedDoesNot() {
        var assigner = SpeakerSlotAssigner()
        let glenSlot = assigner.slot(for: "Glen")
        _ = assigner.slot(for: "Me", isYou: true)
        #expect(assigner.slot(for: "Glen") == glenSlot)
        #expect(assigner.slot(for: "Glen") == glenSlot)
        #expect(assigner.slot(for: "Me", isYou: true) == .you)
    }

    /// The persisted-store half of the same fix: a `.unresolved` entry that was
    /// encoded before this behaviour existed decodes as data with no special
    /// marking at all — retryability comes from the lookup, not the stored
    /// value, so there's nothing to migrate on an older store.
    @Test func aDecodedUnresolvedEntryIsAlsoRetryable() throws {
        var assigner = SpeakerSlotAssigner()
        for n in 1...SpeakerSlot.capacity {
            _ = assigner.slot(for: "speaker-\(n)")
        }
        _ = assigner.slot(for: "over-capacity")
        #expect(assigner.assignments["over-capacity"] == .unresolved)

        let data = try JSONEncoder().encode(assigner)
        var decoded = try JSONDecoder().decode(SpeakerSlotAssigner.self, from: data)
        #expect(decoded.assignments["over-capacity"] == .unresolved)

        decoded.reconcile(liveIDs: Set(decoded.assignments.keys).subtracting(["speaker-1"]))
        #expect(decoded.slot(for: "over-capacity") == .slot(1))
    }

    // MARK: - Rename / merge / capacity reclaim

    @Test func renameTransfersTheExistingSlotToTheNewKey() {
        var assigner = SpeakerSlotAssigner()
        let original = assigner.slot(for: "Speaker 3")
        assigner.rename(from: "Speaker 3", to: "Glen")
        #expect(assigner.slot(for: "Glen") == original)
        #expect(assigner.assignments["Speaker 3"] == nil)
    }

    /// The merge case: "Speaker 3" turns out to be Glen, already separately
    /// identified. Glen's own colour must win, and "Speaker 3"'s number must go
    /// back into the pool rather than staying stranded against capacity.
    @Test func renameIntoAnAlreadySlottedTargetKeepsTheTargetsSlotAndFreesTheSources() {
        var assigner = SpeakerSlotAssigner()
        let glenSlot = assigner.slot(for: "Glen")
        let speaker3Slot = assigner.slot(for: "Speaker 3")
        #expect(glenSlot != speaker3Slot)

        assigner.rename(from: "Speaker 3", to: "Glen")
        #expect(assigner.slot(for: "Glen") == glenSlot)
        #expect(assigner.assignments["Speaker 3"] == nil)

        // "Speaker 3"'s old number is available again for the next new speaker.
        #expect(assigner.slot(for: "Newcomer") == speaker3Slot)
    }

    @Test func renameFromAnUnassignedKeyIsANoOp() {
        var assigner = SpeakerSlotAssigner()
        let glen = assigner.slot(for: "Glen")
        assigner.rename(from: "Nobody Yet", to: "Someone Else")
        #expect(assigner.slot(for: "Glen") == glen)
        #expect(assigner.assignments.count == 1)
    }

    @Test func renameToItselfIsANoOp() {
        var assigner = SpeakerSlotAssigner()
        let glen = assigner.slot(for: "Glen")
        assigner.rename(from: "Glen", to: "Glen")
        #expect(assigner.slot(for: "Glen") == glen)
    }

    @Test func reconcileDropsKeysNoLongerLiveAndFreesTheirNumbers() {
        var assigner = SpeakerSlotAssigner()
        _ = assigner.slot(for: "Glen")
        let mary = assigner.slot(for: "Mary")

        assigner.reconcile(liveIDs: ["Mary"])

        #expect(assigner.assignments == ["Mary": mary])
        // Glen's abandoned number is available again.
        #expect(assigner.slot(for: "Newcomer") == .slot(1))
    }

    /// The exact failure Copilot flagged: a monotonic counter would run out of
    /// numbers after `capacity` renames even though the *live* roster never grows
    /// past one speaker. Renaming and reconciling after each one must keep
    /// capacity keyed to who's actually still there.
    @Test func repeatedRenamesOfOneSpeakerNeverExhaustCapacity() {
        var assigner = SpeakerSlotAssigner()
        var current = "speaker-0"
        _ = assigner.slot(for: current)

        for n in 1...(SpeakerSlot.capacity * 3) {
            let next = "speaker-\(n)"
            assigner.rename(from: current, to: next)
            assigner.reconcile(liveIDs: [next])
            current = next
        }

        #expect(assigner.assignments.count == 1)
        #expect(assigner.slot(for: current) == .slot(1))
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

    // MARK: - Rename / merge continuity, at the `Meeting` seam

    /// The bug Copilot caught: `SpeakerSummary.id` is label-derived, so a plain
    /// `slot(for:)` call after a rename saw an unrecognized key and handed out a
    /// new colour. `relabelSpeaker` has to rekey the assigner itself.
    @Test func relabelingASpeakerKeepsTheirColourInsteadOfAllocatingANewOne() {
        let meeting = Meeting(title: "Office")
        let segment = TranscriptSegment(channel: .me, text: "hi", startTime: 0, endTime: 2)
        segment.speakerLabel = "Speaker 1"
        meeting.segments = [segment]

        let before = meeting.resolveSpeakerSlots(ownerNames: [])
        let originalID = meeting.speakerSummaries[0].id
        let originalSlot = before[originalID]
        #expect(originalSlot != nil)

        meeting.relabelSpeaker(meeting.speakerSummaries[0], to: "Glen")

        let after = meeting.resolveSpeakerSlots(ownerNames: [])
        #expect(after["Glen"] == originalSlot)
        #expect(after[originalID] == nil)
        #expect(after.count == 1)
    }

    /// The merge case: a phantom "Speaker 3" turns out to be Glen. Glen's own
    /// colour must win, and "Speaker 3"'s slot must go back into the pool rather
    /// than staying stranded against the eight-speaker cap.
    @Test func mergingASplitSpeakerKeepsTheTargetsColourAndFreesTheSourcesSlot() {
        let meeting = Meeting(title: "Office")
        meeting.segments = [
            ("Glen", 0.0, 2.0),
            ("Speaker 3", 2.0, 4.0),
        ].map { label, start, end -> TranscriptSegment in
            let segment = TranscriptSegment(channel: .me, text: label, startTime: start, endTime: end)
            segment.speakerLabel = label
            return segment
        }

        let firstPass = meeting.resolveSpeakerSlots(ownerNames: [])
        let glenID = meeting.speakerSummaries.first { $0.label == "Glen" }!.id
        let phantomID = meeting.speakerSummaries.first { $0.label == "Speaker 3" }!.id
        let glenSlot = firstPass[glenID]
        let phantomSlot = firstPass[phantomID]
        #expect(glenSlot != nil)
        #expect(phantomSlot != nil)
        #expect(glenSlot != phantomSlot)

        let phantom = meeting.speakerSummaries.first { $0.label == "Speaker 3" }!
        meeting.relabelSpeaker(phantom, to: "Glen")

        let afterMerge = meeting.resolveSpeakerSlots(ownerNames: [])
        #expect(afterMerge["Glen"] == glenSlot)
        #expect(afterMerge.count == 1)

        // The freed number is available again for whoever's next, not retired.
        let newcomer = TranscriptSegment(channel: .them, text: "hi", startTime: 5, endTime: 6)
        newcomer.speakerLabel = "Mary"
        meeting.segments.append(newcomer)
        let withNewcomer = meeting.resolveSpeakerSlots(ownerNames: [])
        #expect(withNewcomer["Mary"] == phantomSlot)
    }

    /// Renaming the same speaker over and over (an over-eager "let me fix the
    /// spelling" loop, or repeated re-identification landing a new guess each
    /// time) must never run the meeting out of slots — the live roster never
    /// grows past one speaker, so capacity shouldn't think otherwise.
    @Test func repeatedRenamesOfOneSpeakerNeverExhaustMeetingCapacity() {
        let meeting = Meeting(title: "Renamed a lot")
        let segment = TranscriptSegment(channel: .me, text: "hi", startTime: 0, endTime: 2)
        segment.speakerLabel = "Speaker 1"
        meeting.segments = [segment]
        _ = meeting.resolveSpeakerSlots(ownerNames: [])

        var currentLabel = "Speaker 1"
        for n in 1...(SpeakerSlot.capacity * 3) {
            let newLabel = "Name \(n)"
            let summary = meeting.speakerSummaries.first { $0.label == currentLabel }!
            meeting.relabelSpeaker(summary, to: newLabel)
            _ = meeting.resolveSpeakerSlots(ownerNames: [])
            currentLabel = newLabel
        }

        let final = meeting.resolveSpeakerSlots(ownerNames: [])
        #expect(final.count == 1)
        #expect(final[currentLabel] == .slot(1))
    }

    /// The other bug Copilot caught: reconciling *after* allocating meant a dead
    /// key still held its number during the very pass that was supposed to
    /// reclaim it. At full capacity, a single corrected line that was the only
    /// one under its old label — bypassing `relabelSpeaker`'s rekey, the way the
    /// per-line quick-fix menu does — used to come back `.unresolved` even
    /// though its old identity had just vacated a number in this same call.
    @Test func relabelAtCapacityGetsTheFreedNumberInTheSameResolvePass() {
        let meeting = Meeting(title: "Full house")
        var segments: [TranscriptSegment] = []
        for n in 1...SpeakerSlot.capacity {
            let segment = TranscriptSegment(channel: .me, text: "hi", startTime: Double(n), endTime: Double(n) + 1)
            segment.speakerLabel = "Speaker \(n)"
            segments.append(segment)
        }
        meeting.segments = segments
        _ = meeting.resolveSpeakerSlots(ownerNames: [])
        #expect(meeting.speakerSlotAssigner.assignments.count == SpeakerSlot.capacity)

        // The only line under "Speaker 1" gets corrected directly — its old key
        // is genuinely abandoned, not transferred.
        segments[0].assignSpeaker("Glen")

        let resolved = meeting.resolveSpeakerSlots(ownerNames: [])
        #expect(resolved["Glen"] == .slot(1))
        #expect(resolved.count == SpeakerSlot.capacity)
    }
}
