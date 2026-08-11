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
            let body = Self.inline(text)
            let bodyHasLinks = body.runs.contains { $0.link != nil }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .monospacedDigit()
                Text(body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // One element, "1. Ship the fix" — not so a reader loses the marker
            // (an ordered item's number is content, not decoration), but so
            // nothing exposes the bare marker on its own: this HStack has no list
            // semantics for the marker to lean on, and a standalone baseline-
            // aligned "•" also reports an accessibility frame its glyph isn't in,
            // which the contrast audit (#142) then measures as a blank region and
            // flags. Combined, the frame covers the whole row's rendered text.
            //
            // Except when the body carries links: combining would swallow them
            // into one flat label and VoiceOver couldn't focus or open them, so a
            // linked item keeps its children — the marker stays a separate,
            // spoken element ahead of the text, which preserves the ordering an
            // ordered item's number carries.
            .accessibilityElement(children: bodyHasLinks ? .contain : .combine)
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
