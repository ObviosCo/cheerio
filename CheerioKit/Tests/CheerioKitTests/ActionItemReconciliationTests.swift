import Foundation
import Testing

@testable import CheerioKit

/// A persisted action item's trust state can go stale — a line gets relabelled to a
/// guest, or the enrollment marked "me" changes — and export/MCP must never
/// authorize an action off identity that has since been corrected.
@Suite struct ActionItemReconciliationTests {
    @Test func namedItemDemotesWhenItsOwnerStopsBeingTheOwner() {
        let item = ActionItem(
            text: "Draft the proposal", owner: "Jackson", isOwner: true, disposition: .actionable)
        // "Jackson" is no longer an isMe enrollment — say the flag moved to Carter.
        let reconciled = item.reconciled(ownerNames: ["Carter"], meetingHasOwnerLines: true)
        #expect(!reconciled.isOwner)
        #expect(reconciled.disposition == .followUp)
        // The name survives: it's still who committed, now as someone to chase.
        #expect(reconciled.owner == "Jackson")
    }

    @Test func reconciliationNeverPromotes() {
        // Carter's item, and Carter later becomes the owner. The model's original
        // judgement is gone, so the disposition stays a follow-up; only isOwner is
        // allowed to reflect the new identity — and it doesn't, because promotion
        // as a whole is off the table.
        let item = ActionItem(
            text: "Send the contract", owner: "Carter", isOwner: false, disposition: .followUp)
        let reconciled = item.reconciled(ownerNames: ["Carter"], meetingHasOwnerLines: true)
        #expect(reconciled == item)
    }

    @Test func unnamedItemDemotesWhenNoOwnerLinesRemain() {
        // A first-person commitment whose mic lines were all corrected to a guest:
        // "I'll do it" wasn't the owner talking after all.
        let item = ActionItem(text: "Update the roadmap", isOwner: true, disposition: .actionable)
        let reconciled = item.reconciled(ownerNames: ["Jackson"], meetingHasOwnerLines: false)
        #expect(!reconciled.isOwner)
        #expect(reconciled.disposition == .followUp)
    }

    @Test func unnamedItemSurvivesWhileOwnerLinesRemain() {
        let item = ActionItem(text: "Update the roadmap", isOwner: true, disposition: .actionable)
        let reconciled = item.reconciled(ownerNames: ["Jackson"], meetingHasOwnerLines: true)
        #expect(reconciled == item)
    }

    @Test func meetingLevelReconciliationFollowsARelabel() {
        let meeting = Meeting(title: "Standup")
        let line = TranscriptSegment(channel: .me, text: "I'll draft it", startTime: 0, endTime: 5)
        meeting.segments = [line]
        meeting.actionItems = [
            ActionItem(text: "Draft the proposal", isOwner: true, disposition: .actionable)
        ]

        // Untouched: the mic line still resolves to the owner.
        #expect(!meeting.reconcileActionItems(ownerNames: ["Jackson"]))

        // The user corrects the line to a guest; the item must demote.
        line.assignSpeaker("Carter")
        #expect(meeting.reconcileActionItems(ownerNames: ["Jackson"]))
        #expect(meeting.actionItems.map(\.disposition) == [.followUp])
        // And a second pass has nothing left to do.
        #expect(!meeting.reconcileActionItems(ownerNames: ["Jackson"]))
    }

    @Test func exportSerializesReconciledItemsWithoutMutatingTheMeeting() {
        let meeting = Meeting(title: "Standup")
        let line = TranscriptSegment(channel: .me, text: "I'll draft it", startTime: 0, endTime: 5)
        line.assignSpeaker("Carter")
        meeting.segments = [line]
        meeting.actionItems = [
            ActionItem(text: "Draft the proposal", isOwner: true, disposition: .actionable)
        ]

        let export = meeting.export(ownerNames: ["Jackson"])
        #expect(export.actionItems.map(\.disposition) == [.followUp])
        // Export reads through the reconciliation; persisting it is the app's call.
        #expect(meeting.actionItems.map(\.disposition) == [.actionable])
    }

    @Test func decodingEnforcesTheTrustInvariant() throws {
        // Hand-edited or future-buggy-writer JSON claiming a non-owner actionable
        // item comes back demoted rather than trusted.
        let json = """
            {"text":"Send the contract","owner":"Carter","isOwner":false,"disposition":"actionable"}
            """
        let item = try JSONDecoder().decode(ActionItem.self, from: Data(json.utf8))
        #expect(item.disposition == .followUp)
    }

    @Test func mergeKeepsTheChaseableNameWhenSightingsDisagree() {
        // One chunk attributed the commitment to the owner, another to Carter. The
        // merge demotes — and a follow-up's name is who to chase, so it must be
        // Carter's, not the owner's own name telling the user to chase themselves.
        let items = ActionItem.resolved(
            from: [
                ActionItemDraft(task: "Send the contract", owner: "Jackson", disposition: .actionable),
                ActionItemDraft(task: "Send the contract", owner: "Carter", disposition: .followUp),
            ],
            ownerNames: ["Jackson"]
        )
        #expect(items.count == 1)
        #expect(items[0].isOwner == false)
        #expect(items[0].disposition == .followUp)
        #expect(items[0].owner == "Carter")
    }
}
