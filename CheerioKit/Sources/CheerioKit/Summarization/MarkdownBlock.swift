import Foundation

/// One block of the Markdown ``SummarizationEngine`` produces.
///
/// SwiftUI's `Text` applies only *inline* Markdown, so headings and list items
/// reach the screen as literal "## " and "- " — which is most of what the
/// summarizer emits. Splitting the notes into blocks first lets the view render
/// each one properly.
public enum MarkdownBlock: Equatable, Sendable {
    /// `level` is the number of leading hashes, so 1 for `#`, 2 for `##`.
    case heading(level: Int, text: String)
    /// `marker` is what to draw in the gutter: a bullet, or the author's own number.
    case listItem(marker: String, text: String)
    case paragraph(String)
}

extension MarkdownBlock {
    /// Splits Markdown into blocks.
    ///
    /// Only the constructs the summarizer actually emits are recognized; anything
    /// else stays a paragraph, so unexpected syntax degrades to plain text rather
    /// than vanishing.
    public static func blocks(in markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        // Consecutive plain lines are one paragraph, as in Markdown proper.
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph = []
        }

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
            } else if let heading = heading(from: line) {
                flushParagraph()
                blocks.append(heading)
            } else if let item = listItem(from: line) {
                flushParagraph()
                blocks.append(item)
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        return blocks
    }

    /// "## Summary" — a run of hashes, then a space. "#Summary" is not a heading.
    private static func heading(from line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }
        let rest = line.dropFirst(hashes.count)
        guard !hashes.isEmpty, rest.first == " " else { return nil }
        return .heading(level: hashes.count, text: rest.trimmingCharacters(in: .whitespaces))
    }

    /// "- item", "* item", "+ item", or "1. item" / "1) item".
    private static func listItem(from line: String) -> MarkdownBlock? {
        if let first = line.first, "-*+".contains(first), line.dropFirst().first == " " {
            let text = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return .listItem(marker: "•", text: text)
        }

        // Keep the author's number rather than renumbering, so a list that starts
        // at 3 still reads as a continuation.
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let afterDigits = line.dropFirst(digits.count)
        guard let punctuation = afterDigits.first, punctuation == "." || punctuation == ")",
              afterDigits.dropFirst().first == " "
        else { return nil }
        let text = afterDigits.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return .listItem(marker: "\(digits)\(punctuation)", text: text)
    }
}
