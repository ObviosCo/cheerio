import Foundation
import Testing

@testable import CheerioKit

@Suite struct MarkdownBlockTests {
    /// The shape SummarizationEngine actually returns.
    private let notes = """
        ## Summary
        Jackson and Carter discussed voice differentiation.
        It went well.

        ## Key points
        - Jackson recorded Carter's voice
        - Carter expressed concern

        ### Decisions
        1. Keep trying
        """

    @Test func splitsSummarizerNotesIntoBlocks() {
        #expect(
            MarkdownBlock.blocks(in: notes) == [
                .heading(level: 2, text: "Summary"),
                .paragraph("Jackson and Carter discussed voice differentiation. It went well."),
                .heading(level: 2, text: "Key points"),
                .listItem(marker: "•", text: "Jackson recorded Carter's voice"),
                .listItem(marker: "•", text: "Carter expressed concern"),
                .heading(level: 3, text: "Decisions"),
                .listItem(marker: "1.", text: "Keep trying"),
            ])
    }

    @Test func recognizesEveryBulletMarker() {
        #expect(
            MarkdownBlock.blocks(in: "- a\n* b\n+ c") == [
                .listItem(marker: "•", text: "a"),
                .listItem(marker: "•", text: "b"),
                .listItem(marker: "•", text: "c"),
            ])
    }

    @Test func keepsTheAuthorsOwnNumbering() {
        #expect(
            MarkdownBlock.blocks(in: "3. third\n4) fourth") == [
                .listItem(marker: "3.", text: "third"),
                .listItem(marker: "4)", text: "fourth"),
            ])
    }

    @Test func unrecognizedSyntaxStaysAParagraph() {
        // Text must never disappear just because it isn't a construct we handle.
        #expect(MarkdownBlock.blocks(in: "#NoSpace") == [.paragraph("#NoSpace")])
        #expect(MarkdownBlock.blocks(in: "###") == [.paragraph("###")])
        #expect(MarkdownBlock.blocks(in: "-nospace") == [.paragraph("-nospace")])
        #expect(MarkdownBlock.blocks(in: "1.nospace") == [.paragraph("1.nospace")])
        // A year, not a list item.
        #expect(MarkdownBlock.blocks(in: "2026. What a year") == [.paragraph("2026. What a year")])
    }

    @Test func leavesInlineMarkupForTextToRender() {
        // Bold and links are `Text`'s job, so they pass through untouched.
        #expect(
            MarkdownBlock.blocks(in: "- **Owner:** Jackson") == [
                .listItem(marker: "•", text: "**Owner:** Jackson")
            ])
    }

    @Test func emptyNotesProduceNoBlocks() {
        #expect(MarkdownBlock.blocks(in: "").isEmpty)
        #expect(MarkdownBlock.blocks(in: "\n\n   \n").isEmpty)
    }
}
