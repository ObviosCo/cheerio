import Foundation
import Testing

@testable import CheerioKit

/// `SummarizationEngine.chunked` is what keeps the map-reduce path inside the on-device
/// model's context window. Issue #13: a single transcript line longer than the budget
/// used to go through whole — the one thing the chunker exists to prevent — and, when
/// that oversized line came first, left an empty chunk ahead of it that turned into a
/// wasted model round-trip. These pin the fix: an over-budget line is split at a word
/// boundary into budget-sized pieces, nothing is dropped, and no chunk ever exceeds
/// `chunkCharacterBudget`.
@Suite struct SummarizationEngineChunkingTests {
    private let engine = SummarizationEngine()

    /// Every non-empty line here is prefixed with a speaker label, same as real
    /// transcript lines — chunking must not care what the content looks like, only how
    /// long it is.
    private func line(_ length: Int, label: String = "[Me]") -> String {
        let prefix = "\(label) "
        let bodyLength = max(0, length - prefix.count)
        return prefix + String(repeating: "a", count: bodyLength)
    }

    /// A line built from real words instead of one giant token, so a word-boundary
    /// split has somewhere sensible to break.
    private func wordyLine(wordCount: Int, wordLength: Int = 9) -> String {
        Array(repeating: String(repeating: "w", count: wordLength), count: wordCount).joined(separator: " ")
    }

    // MARK: - Boundary cases

    @Test func lineExactlyAtBudgetStaysWhole() async {
        let text = line(engine.chunkCharacterBudget)
        let chunks = await engine.chunked(text)

        for chunk in chunks {
            #expect(chunk.count <= engine.chunkCharacterBudget)
        }
        // The line fits, so it must survive as a single whole chunk — not split, and
        // not preceded by an empty one (issue #13's second defect). Any chunk beyond
        // that first one can only be the trailing line-separator newline, which
        // `mapReduce` already discards as blank before it ever reaches the model.
        let substantive = chunks.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        #expect(substantive == [text])
    }

    @Test func lineJustOverBudgetIsSplitNotDropped() async {
        let text = wordyLine(wordCount: 900)  // ~8_999 chars, just over an 8_000 budget
        #expect(text.count > engine.chunkCharacterBudget)

        let chunks = await engine.chunked(text)

        #expect(chunks.count > 1)
        for chunk in chunks {
            #expect(chunk.count <= engine.chunkCharacterBudget)
            // Never a literal empty chunk — issue #13's second defect, where an
            // over-long first line pushed an empty chunk ahead of itself.
            #expect(!chunk.isEmpty)
        }
        #expect(wordsPreserved(originalText: text, chunks: chunks))
    }

    @Test func lineManyTimesOverBudgetSplitsIntoSeveralWholeChunks() async {
        let text = wordyLine(wordCount: 900 * 5)  // roughly 5x the budget
        let chunks = await engine.chunked(text)

        #expect(chunks.count >= 5)
        for chunk in chunks {
            #expect(chunk.count <= engine.chunkCharacterBudget)
            #expect(!chunk.isEmpty)
        }
        #expect(wordsPreserved(originalText: text, chunks: chunks))
    }

    /// A single token with no space anywhere near the limit has no word boundary to
    /// break at, so it's the one case that gets a hard cut rather than a word split —
    /// but it must still never exceed the budget or drop a character.
    @Test func unbrokenTokenLongerThanBudgetIsHardSplitWithinBudget() async {
        let text = String(repeating: "x", count: engine.chunkCharacterBudget * 3)
        let chunks = await engine.chunked(text)

        for chunk in chunks {
            #expect(chunk.count <= engine.chunkCharacterBudget)
        }
        let reconstructed = chunks.joined().replacingOccurrences(of: "\n", with: "")
        #expect(reconstructed == text)
    }

    // MARK: - Speaker prefix (PR #101 review)

    /// `Meeting.transcriptText` labels every line `"[speaker] text"`, and `extract`
    /// attributes action items by that per-line label. Before this, only the first
    /// fragment of a split line kept it — a commitment landing in a later fragment
    /// would silently lose attribution. Every fragment must carry the label now.
    @Test func labeledOversizedLineCarriesLabelOnEveryFragment() async {
        let label = "[Carter] "
        let text = label + wordyLine(wordCount: 900)  // label + ~8_999 chars of body
        #expect(text.count > engine.chunkCharacterBudget)

        let chunks = await engine.chunked(text)
        let substantive = chunks.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        #expect(substantive.count > 1)
        for chunk in chunks {
            #expect(chunk.count <= engine.chunkCharacterBudget)
        }
        #expect(substantive.allSatisfy { $0.hasPrefix(label) })

        // Strip the repeated label before comparing content — carrying it onto every
        // fragment duplicates it in the reconstruction by design, so a plain
        // `wordsPreserved` comparison against the original would fail here.
        let reconstructedBody = substantive.map { String($0.dropFirst(label.count)) }.joined(separator: " ")
        let originalBody = String(text.dropFirst(label.count))
        #expect(
            originalBody.split(whereSeparator: \.isWhitespace).elementsEqual(
                reconstructedBody.split(whereSeparator: \.isWhitespace)
            ))
    }

    /// A label wide enough to eat half the budget on its own can't be carried into
    /// every fragment and still leave room for content — this is synthetic (real
    /// speaker labels are short names), but the guard must still degrade safely:
    /// bounded chunks, no infinite loop, nothing dropped.
    @Test func pathologicallyLongPrefixFallsBackToHardWrapWithinBudget() async {
        let hugeLabel = "[" + String(repeating: "L", count: engine.chunkCharacterBudget) + "] "
        let text = hugeLabel + "some content that follows the oversized label"
        #expect(text.count > engine.chunkCharacterBudget)

        let chunks = await engine.chunked(text)

        #expect(!chunks.isEmpty)
        for chunk in chunks {
            #expect(chunk.count <= engine.chunkCharacterBudget)
            #expect(!chunk.isEmpty)
        }
        let reconstructed = chunks.joined().replacingOccurrences(of: "\n", with: "")
        #expect(reconstructed == text)
    }

    // MARK: - Empty lines

    @Test func emptyLinesMixedWithContentDoNotBreakChunking() async {
        let text = [
            "[Me] Let's get started.",
            "",
            "",
            "[Them] Sounds good.",
            "",
            wordyLine(wordCount: 900),
            "",
            "[Me] Great, that's everything.",
        ].joined(separator: "\n")

        let chunks = await engine.chunked(text)

        for chunk in chunks {
            #expect(chunk.count <= engine.chunkCharacterBudget)
        }
        #expect(wordsPreserved(originalText: text, chunks: chunks))
    }

    // MARK: - Property: budget and content preservation across varied inputs

    @Test(
        arguments: [
            "",
            "[Me] short line",
            "[Me] short line\n[Them] another short line\n",
            "\n\n\n",
            Array(repeating: "[Me] a normal-length transcript line here.", count: 400).joined(separator: "\n"),
        ]
    )
    func everyChunkFitsBudgetAndContentIsPreserved(_ text: String) async {
        let chunks = await engine.chunked(text)

        for chunk in chunks {
            #expect(chunk.count <= engine.chunkCharacterBudget)
        }
        #expect(wordsPreserved(originalText: text, chunks: chunks))
    }

    @Test func manyLinesSomeOverBudgetAlwaysFitAndPreserveContent() async {
        var lines: [String] = []
        for i in 0..<50 {
            switch i % 7 {
            case 0: lines.append("")
            case 1: lines.append(wordyLine(wordCount: 900))  // just over budget
            case 2: lines.append(wordyLine(wordCount: 900 * 3))  // several times over
            default: lines.append("[Speaker \(i)] a perfectly ordinary line of dialogue.")
            }
        }
        let text = lines.joined(separator: "\n")
        let chunks = await engine.chunked(text)

        #expect(!chunks.isEmpty)
        for chunk in chunks {
            #expect(chunk.count <= engine.chunkCharacterBudget)
        }
        #expect(wordsPreserved(originalText: text, chunks: chunks))
    }

    /// Concatenating every chunk must reproduce every word of the original, in order —
    /// splitting must never silently drop content. Whitespace layout is allowed to
    /// shift (a split line trades its single newline for none, or gains one at the
    /// point of the break), so the comparison is over whitespace-separated words rather
    /// than exact bytes.
    private func wordsPreserved(originalText: String, chunks: [String]) -> Bool {
        let originalWords = originalText.split(whereSeparator: \.isWhitespace)
        let reconstructedWords = chunks.joined(separator: " ").split(whereSeparator: \.isWhitespace)
        return originalWords.elementsEqual(reconstructedWords)
    }
}
