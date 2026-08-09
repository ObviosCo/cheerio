import CheerioKit
import SwiftUI

/// Renders Markdown — the notes ``SummarizationEngine`` produces, and (#108) the
/// rough notes typed by hand.
///
/// `Text(LocalizedStringKey(markdown))` looks like it handles this, but it applies
/// only inline markup — headings and bullets show up as literal "## " and "- ",
/// which is the bulk of the summarizer's output. So block structure is resolved by
/// ``MarkdownBlock`` and only inline markup is left to `Text`.
struct MarkdownNotesView: View {
    let markdown: String
    /// See ``MarkdownBlock/blocks(in:preservingLineBreaksInParagraphs:)`` — pass
    /// `true` for rough notes, whose lines are separate thoughts with no blank
    /// line between them. The enhanced-notes call site above leaves this `false`,
    /// since the summarizer's prose wraps a sentence across lines on purpose.
    var preservesLineBreaksInParagraphs = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(
                Array(
                    MarkdownBlock.blocks(
                        in: markdown,
                        preservingLineBreaksInParagraphs: preservesLineBreaksInParagraphs
                    ).enumerated()
                ),
                id: \.offset
            ) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(Self.font(forHeadingLevel: level))
                // Separates a section from the one above without a blank-line hack.
                .padding(.top, 6)
        case .listItem(let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(Self.inline(text))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .paragraph(let text):
            Text(Self.inline(text))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func font(forHeadingLevel level: Int) -> Font {
        switch level {
        case 1: .title3.weight(.semibold)
        case 2: .headline
        default: .subheadline.weight(.semibold)
        }
    }

    /// Bold, italics, and links. Falls back to the raw text when a line isn't valid
    /// Markdown, so malformed notes still read.
    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
