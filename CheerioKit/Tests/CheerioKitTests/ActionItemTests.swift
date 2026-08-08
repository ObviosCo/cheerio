import Foundation
import SwiftData
import Testing

@testable import CheerioKit

/// `ActionItem.resolved(from:ownerNames:)` is the enforcement half of the speaker-trust
/// rule: it decides what an agent is allowed to do on the user's behalf. Prompting the
/// model to attribute correctly is a hint; this function is the guarantee, so every
/// input that could reach it is pinned down here.
@Suite struct ActionItemGuardTests {
    private let ownerNames: Set<String> = ["Jackson"]

    private func draft(
        _ task: String = "Draft the proposal",
        owner: String,
        disposition: ActionItem.Disposition = .actionable
    ) -> ActionItemDraft {
        ActionItemDraft(task: task, owner: owner, disposition: disposition)
    }

    // MARK: - The owner's own commitments

    @Test func ownerCommitmentStaysActionable() {
        let items = ActionItem.resolved(from: [draft(owner: "Me")], ownerNames: ownerNames)
        #expect(items == [ActionItem(text: "Draft the proposal", isOwner: true, disposition: .actionable)])
    }

    @Test func enrolledOwnerNameStaysActionableAndKeepsTheName() {
        // The realistic case: diarization labelled the owner's lines "Jackson", so
        // that's the label the model attributes to.
        let items = ActionItem.resolved(from: [draft(owner: "Jackson")], ownerNames: ownerNames)
        #expect(items == [ActionItem(text: "Draft the proposal", owner: "Jackson", isOwner: true, disposition: .actionable)])
    }

    @Test func ownerNameMatchingIgnoresCaseAndDecoration() {
        // Free text the model echoed back, not a label we minted — so unlike
        // `Meeting.isOwnerAttributed`, matching here is lenient about spelling.
        for spelling in ["jackson", "JACKSON", "[Jackson]", "Jackson:", " Jackson "] {
            let items = ActionItem.resolved(from: [draft(owner: spelling)], ownerNames: ownerNames)
            #expect(items.map(\.isOwner) == [true], "\(spelling) should resolve to the owner")
            #expect(items.map(\.owner) == ["Jackson"], "\(spelling) should normalize to the enrolled name")
        }
    }

    @Test func firstPersonSpellingsResolveToTheOwner() {
        for spelling in ["me", "Me", "I", "[Me]", "(me)", "myself", "the user", "self"] {
            let items = ActionItem.resolved(from: [draft(owner: spelling)], ownerNames: ownerNames)
            #expect(items.map(\.disposition) == [.actionable], "\(spelling) should resolve to the owner")
            // No name to show: "Me" identifies the owner without naming them.
            #expect(items.map(\.owner) == [String?.none])
        }
    }

    @Test func firstPersonStillResolvesWithNobodyEnrolled() {
        // Degenerate but real: no voice is marked "this is me" yet. "[Me]" is still the
        // label an undiarized mic line carries, and mic lines are the owner's — the same
        // channel half of the rule `Meeting.isOwnerAttributed` applies.
        let items = ActionItem.resolved(from: [draft(owner: "Me")], ownerNames: [])
        #expect(items.map(\.disposition) == [.actionable])
    }

    @Test func aNameNobodyEnrolledUnderIsNotTheOwner() {
        // Mirrors `Meeting.isOwnerAttributed`: with nothing enrolled, a name is just a
        // name, and crediting "Jackson" to the owner would be the model's word alone.
        let items = ActionItem.resolved(from: [draft(owner: "Jackson")], ownerNames: [])
        #expect(items == [ActionItem(text: "Draft the proposal", owner: "Jackson", isOwner: false, disposition: .followUp)])
    }

    // MARK: - Demotion

    @Test func namedGuestIsDemotedButKeepsTheirName() {
        // The case the invariant exists for: the model said a guest's commitment was
        // actionable, and acting on it would mean doing Carter's work for him.
        let items = ActionItem.resolved(
            from: [draft("Send the contract", owner: "Carter")],
            ownerNames: ownerNames
        )
        #expect(items == [ActionItem(text: "Send the contract", owner: "Carter", isOwner: false, disposition: .followUp)])
    }

    @Test func diarizerPlaceholderIsDemoted() {
        // "Speaker 2" is a voice that couldn't be named. It's still not the owner.
        let items = ActionItem.resolved(from: [draft(owner: "Speaker 2")], ownerNames: ownerNames)
        #expect(items.map(\.isOwner) == [false])
        #expect(items.map(\.disposition) == [.followUp])
        #expect(items.map(\.owner) == ["Speaker 2"])
    }

    @Test func unattributedItemsDefaultToFollowUp() {
        for spelling in ["Unassigned", "unknown", "none", "nobody", "N/A", "TBD", "", "  ", "-", "?", "Them", "someone"] {
            let items = ActionItem.resolved(from: [draft(owner: spelling)], ownerNames: ownerNames)
            #expect(items.map(\.disposition) == [.followUp], "\(spelling) should not be actionable")
            #expect(items.map(\.isOwner) == [false], "\(spelling) should not be the owner")
            #expect(items.map(\.owner) == [String?.none], "\(spelling) is not a name to chase")
        }
    }

    @Test func groupCommitmentsAreNotTheOwners() {
        // "We'll figure it out" includes the owner and also everyone else; an agent
        // can't tell which part was theirs, so it tracks rather than acts.
        for spelling in ["we", "us", "the team", "Team", "everyone", "both", "the group"] {
            let items = ActionItem.resolved(from: [draft(owner: spelling)], ownerNames: ownerNames)
            #expect(items.map(\.disposition) == [.followUp], "\(spelling) should not be actionable")
            #expect(items.map(\.owner) == [String?.none], "\(spelling) names nobody")
        }
    }

    @Test func theGuardOnlyEverDemotes() {
        // The model marked the owner's own commitment a follow-up — it may have seen a
        // dependency ("I'll send it once Carter signs") that owner resolution can't.
        // Nothing here promotes it back.
        let items = ActionItem.resolved(
            from: [draft(owner: "Jackson", disposition: .followUp)],
            ownerNames: ownerNames
        )
        #expect(items.map(\.disposition) == [.followUp])
        #expect(items.map(\.isOwner) == [true])
    }

    @Test func blankTasksAreDropped() {
        let items = ActionItem.resolved(
            from: [draft("", owner: "Me"), draft("   \n ", owner: "Me"), draft("Ship it", owner: "Me")],
            ownerNames: ownerNames
        )
        #expect(items.map(\.text) == ["Ship it"])
    }

    @Test func taskTextIsTrimmed() {
        let items = ActionItem.resolved(from: [draft("  Ship it\n", owner: "Me")], ownerNames: ownerNames)
        #expect(items.map(\.text) == ["Ship it"])
    }

    @Test func noDraftsMeansNoItems() {
        #expect(ActionItem.resolved(from: [], ownerNames: ownerNames).isEmpty)
    }

    // MARK: - Merging across map-reduce chunks

    @Test func theSameCommitmentFromTwoChunksMergesOnce() {
        // Chunk boundaries land mid-conversation, so the same commitment gets restated
        // and re-extracted with different punctuation and casing.
        let items = ActionItem.resolved(
            from: [draft("Draft the proposal", owner: "Me"), draft("draft the proposal.", owner: "Me")],
            ownerNames: ownerNames
        )
        #expect(items == [ActionItem(text: "Draft the proposal", isOwner: true, disposition: .actionable)])
    }

    @Test func conflictingAttributionMergesConservatively() {
        // One chunk credited the owner, another credited Carter. An agent doing Carter's
        // work is the outcome to avoid, so the disagreement resolves to a follow-up.
        let items = ActionItem.resolved(
            from: [draft("Send the contract", owner: "Me"), draft("Send the contract", owner: "Carter")],
            ownerNames: ownerNames
        )
        #expect(items == [ActionItem(text: "Send the contract", owner: "Carter", isOwner: false, disposition: .followUp)])
    }

    @Test func aFollowUpInEitherChunkWinsOverAnActionable() {
        let items = ActionItem.resolved(
            from: [
                draft("Draft the proposal", owner: "Jackson", disposition: .actionable),
                draft("Draft the proposal", owner: "Jackson", disposition: .followUp),
            ],
            ownerNames: ownerNames
        )
        #expect(items.map(\.disposition) == [.followUp])
    }

    @Test func aNameFromEitherChunkIsKept() {
        // Unattributed in one chunk, named in the next: the name is the useful half.
        let items = ActionItem.resolved(
            from: [draft("Send the contract", owner: "Unassigned"), draft("Send the contract", owner: "Carter")],
            ownerNames: ownerNames
        )
        #expect(items.map(\.owner) == ["Carter"])
    }

    @Test func mergingKeepsTheFirstPositionAndSpelling() {
        let items = ActionItem.resolved(
            from: [
                draft("Book the venue", owner: "Me"),
                draft("Send the contract", owner: "Carter"),
                draft("book the venue!", owner: "Me"),
            ],
            ownerNames: ownerNames
        )
        #expect(items.map(\.text) == ["Book the venue", "Send the contract"])
    }

    @Test func distinctCommitmentsAreNotMerged() {
        let items = ActionItem.resolved(
            from: [draft("Book the venue", owner: "Me"), draft("Book the caterer", owner: "Me")],
            ownerNames: ownerNames
        )
        #expect(items.count == 2)
    }
}

/// The rendering and persistence either side of the guard.
@Suite struct ActionItemNotesTests {
    private static let notes = EnhancedNotes(
        summary: "Kickoff.",
        keyPoints: ["Scope is fixed"],
        decisions: ["Ship Friday"],
        actionItems: [
            ActionItem(text: "Draft the proposal", isOwner: true, disposition: .actionable),
            ActionItem(text: "Send the contract", owner: "Carter", isOwner: false, disposition: .followUp),
            ActionItem(text: "Decide on pricing", isOwner: false, disposition: .followUp),
        ]
    )

    @Test func markdownSplitsActionItemsFromFollowUps() {
        #expect(
            Self.notes.markdown == """
                ## Summary
                Kickoff.

                ## Key points
                - Scope is fixed

                ## Decisions
                - Ship Friday

                ## Action items
                - [ ] Draft the proposal

                ## Follow-ups
                - [ ] Send the contract — Carter
                - [ ] Decide on pricing
                """)
    }

    @Test func markdownOmitsSectionsWithNothingInThem() {
        let notes = EnhancedNotes(
            summary: "Kickoff.",
            keyPoints: ["Scope is fixed"],
            decisions: [],
            actionItems: [ActionItem(text: "Draft the proposal", isOwner: true, disposition: .actionable)]
        )
        #expect(!notes.markdown.contains("## Decisions"))
        #expect(!notes.markdown.contains("## Follow-ups"))
        #expect(notes.markdown.contains("## Action items"))
    }

    @Test func aFollowUpOnlyMeetingRendersNoActionItemsSection() {
        let notes = EnhancedNotes(
            summary: "Kickoff.",
            keyPoints: [],
            decisions: [],
            actionItems: [ActionItem(text: "Send the contract", owner: "Carter", isOwner: false, disposition: .followUp)]
        )
        #expect(!notes.markdown.contains("## Action items"))
        #expect(notes.markdown.contains("## Follow-ups"))
    }

    @Test func actionItemsSurviveTheStore() throws {
        // The items are what the callback and MCP server read, so they have to outlive
        // the process that generated them — this is the additive SwiftData attribute
        // doing that, not just the in-memory array.
        let container = try ModelContainer(
            for: Meeting.self, TranscriptSegment.self, EnrolledSpeaker.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let meeting = Meeting(title: "Kickoff")
        meeting.actionItems = Self.notes.actionItems
        let context = ModelContext(container)
        context.insert(meeting)
        try context.save()

        let reopened = try ModelContext(container).fetch(FetchDescriptor<Meeting>())
        #expect(reopened.count == 1)
        #expect(reopened.first?.actionItems == Self.notes.actionItems)
    }

    @Test func aMeetingWithoutNotesHasNoActionItems() {
        // The default that makes the migration additive.
        #expect(Meeting(title: "Kickoff").actionItems.isEmpty)
    }
}
