import Foundation
import FoundationModels

/// Structured output for enhanced meeting notes, generated on-device.
@Generable
public struct EnhancedNotes: Sendable {
    @Guide(description: "2-4 sentence summary of what the meeting was about and its outcome")
    public var summary: String

    @Guide(description: "The most important points discussed, 3-8 items")
    public var keyPoints: [String]

    @Guide(description: "Decisions that were made, if any")
    public var decisions: [String]

    @Guide(description: "Concrete action items with owners when identifiable")
    public var actionItems: [ActionItem]
}

@Generable
public struct ActionItem: Sendable {
    @Guide(description: "What needs to be done")
    public var task: String

    @Guide(description: "Who is responsible: 'Me', a name mentioned in the meeting, or 'Unassigned'")
    public var owner: String
}

/// Wraps the Foundation Models framework to turn a transcript + rough notes
/// into enhanced notes. Uses the on-device system model by default.
public actor SummarizationEngine {
    public enum SummarizationError: Error {
        case modelUnavailable(String)
    }

    /// Approximate character budget per chunk. The on-device model's context
    /// window is ~4k tokens, so long transcripts are summarized map-reduce style.
    private let chunkCharacterBudget = 8_000

    public init() {}

    public func generateEnhancedNotes(transcript: String, roughNotes: String) async throws -> EnhancedNotes {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw SummarizationError.modelUnavailable("\(model.availability)")
        }

        let condensedTranscript: String
        if transcript.count > chunkCharacterBudget {
            condensedTranscript = try await mapReduce(transcript: transcript)
        } else {
            condensedTranscript = transcript
        }

        let session = LanguageModelSession(
            instructions: """
                You turn meeting transcripts and the user's rough notes into clean, \
                structured meeting notes.

                Each transcript line is prefixed with a speaker label. [Me] is the user. \
                [Them] means someone other than the user whose identity is unknown. \
                A label like [Speaker 2] means a distinct voice that could not be named — \
                do not guess who it is, and do not assume it is the user. Any other label \
                is a person's name.

                Only attribute a decision or action item to someone when their label \
                makes it clear. Otherwise say the group decided it.

                The user's rough notes indicate what they found important — weight them \
                heavily.
                """)

        let prompt = """
            Rough notes from the user:
            \(roughNotes.isEmpty ? "(none)" : roughNotes)

            Transcript:
            \(condensedTranscript)
            """

        let response = try await session.respond(to: prompt, generating: EnhancedNotes.self)
        return response.content
    }

    /// Summarize transcript chunks independently, then join. Keeps each
    /// LanguageModelSession call within the on-device context window.
    private func mapReduce(transcript: String) async throws -> String {
        var summaries: [String] = []
        for chunk in chunked(transcript) {
            let session = LanguageModelSession(
                instructions: """
                    Condense this portion of a meeting transcript into a dense summary. \
                    Preserve names, numbers, decisions, and commitments verbatim.
                    """)
            let response = try await session.respond(to: chunk)
            summaries.append(response.content)
        }
        return summaries.joined(separator: "\n\n")
    }

    private func chunked(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.count + line.count > chunkCharacterBudget {
                chunks.append(current)
                current = ""
            }
            current += line + "\n"
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

extension EnhancedNotes {
    /// Markdown rendering for storage and export.
    public var markdown: String {
        var out = "## Summary\n\(summary)\n\n## Key points\n"
        out += keyPoints.map { "- \($0)" }.joined(separator: "\n")
        if !decisions.isEmpty {
            out += "\n\n## Decisions\n" + decisions.map { "- \($0)" }.joined(separator: "\n")
        }
        if !actionItems.isEmpty {
            out += "\n\n## Action items\n" + actionItems.map { "- [ ] \($0.task) — \($0.owner)" }.joined(separator: "\n")
        }
        return out
    }
}
