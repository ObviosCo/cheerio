import Foundation
import FoundationModels

/// Enhanced meeting notes, after ``ActionItem/resolved(from:ownerNames:)`` has vetted
/// the attribution — what the app stores, renders, and exports.
public struct EnhancedNotes: Sendable, Equatable {
    public var summary: String
    public var keyPoints: [String]
    public var decisions: [String]
    public var actionItems: [ActionItem]

    public init(summary: String, keyPoints: [String], decisions: [String], actionItems: [ActionItem]) {
        self.summary = summary
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
    }
}

/// One extraction pass' output, straight from the model and unvetted — see
/// ``ActionItemDraft``.
@Generable
public struct NotesDraft: Sendable {
    @Guide(description: "2-4 sentence summary of what the meeting was about and its outcome")
    public var summary: String

    @Guide(description: "The most important points discussed, 3-8 items")
    public var keyPoints: [String]

    @Guide(description: "Decisions that were made, if any")
    public var decisions: [String]

    @Guide(description: "Concrete commitments anyone made, with the speaker who made each one")
    public var actionItems: [ActionItemDraft]
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

    private let model: SystemLanguageModel

    /// - Parameter model: injected rather than reached for, so v2 can hand in another
    ///   model through the WWDC26 `LanguageModel` protocol without this actor changing.
    public init(model: SystemLanguageModel = .default) {
        self.model = model
    }

    /// - Parameter ownerNames: enrolled `isMe` speaker names — the labels the owner's
    ///   own lines carry in `transcript`. They ground attribution twice over: the
    ///   instructions name them so the model knows which speaker is the user, and
    ///   ``ActionItem/resolved(from:ownerNames:)`` enforces it afterwards regardless of
    ///   what the model made of that. Threaded in from the caller for the same reason
    ///   ``MeetingExport`` takes them — this stays free of a `ModelContext`.
    public func generateEnhancedNotes(
        transcript: String,
        roughNotes: String,
        ownerNames: Set<String>
    ) async throws -> EnhancedNotes {
        guard case .available = model.availability else {
            throw SummarizationError.modelUnavailable("\(model.availability)")
        }

        guard transcript.count > chunkCharacterBudget else {
            let draft = try await extract(from: transcript, roughNotes: roughNotes, ownerNames: ownerNames)
            return notes(from: [draft], summary: draft.summary, ownerNames: ownerNames)
        }
        return try await mapReduce(transcript: transcript, roughNotes: roughNotes, ownerNames: ownerNames)
    }

    /// Extracts from each chunk, then merges.
    ///
    /// The map step runs the *structured* extraction per chunk rather than condensing
    /// each chunk to prose and extracting once at the end. Condensing first threw away
    /// the speaker labels before anything had attributed a commitment, so no amount of
    /// prompting downstream could separate the owner's "I'll do it" from a guest's.
    ///
    /// Only the prose summary needs a second model pass. The lists are merged
    /// deterministically, which is what carries owners through the reduce verbatim —
    /// and re-extracting them from condensed prose is exactly how attribution would get
    /// lost or invented.
    private func mapReduce(
        transcript: String,
        roughNotes: String,
        ownerNames: Set<String>
    ) async throws -> EnhancedNotes {
        var drafts: [NotesDraft] = []
        // Blank chunks are skipped rather than sent: the chunker can emit one when a
        // single line exceeds the budget (issue #13), and a structured extraction over
        // nothing invites invented action items. #13's overflow itself is untouched.
        for chunk in chunked(transcript) where !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            drafts.append(try await extract(from: chunk, roughNotes: roughNotes, ownerNames: ownerNames))
        }
        let summary = try await reduceSummary(of: drafts.map(\.summary), roughNotes: roughNotes)
        return notes(from: drafts, summary: summary, ownerNames: ownerNames)
    }

    private func extract(from transcript: String, roughNotes: String, ownerNames: Set<String>) async throws -> NotesDraft {
        let session = LanguageModelSession(model: model, instructions: Self.instructions(ownerNames: ownerNames))
        let prompt = """
            Rough notes from the user:
            \(roughNotes.isEmpty ? "(none)" : roughNotes)

            Transcript:
            \(transcript)
            """
        let response = try await session.respond(to: prompt, generating: NotesDraft.self)
        return response.content
    }

    /// The one prose pass of the reduce. A single chunk needs no second opinion on its
    /// own summary, so it doesn't get one.
    private func reduceSummary(of summaries: [String], roughNotes: String) async throws -> String {
        guard summaries.count > 1 else { return summaries.first ?? "" }

        let session = LanguageModelSession(
            model: model,
            instructions: """
                Write a 2-4 sentence summary of one meeting from summaries of its \
                consecutive sections. Introduce nothing the sections don't say. The \
                user's rough notes indicate what they found important — weight them \
                heavily.
                """)
        let prompt = """
            Rough notes from the user:
            \(roughNotes.isEmpty ? "(none)" : roughNotes)

            Section summaries:
            \(summaries.joined(separator: "\n\n"))
            """
        return try await session.respond(to: prompt).content
    }

    /// Folds one or more extraction passes into the notes.
    ///
    /// Every path through this actor lands here, which is what guarantees the trust
    /// invariant is applied once and can't be skipped by the map-reduce route.
    private func notes(from drafts: [NotesDraft], summary: String, ownerNames: Set<String>) -> EnhancedNotes {
        EnhancedNotes(
            summary: summary,
            // Unioned rather than re-summarized: a longer meeting genuinely has more key
            // points, and asking the model to pick a global 8 from chunk summaries is
            // another pass in which a detail can quietly disappear.
            keyPoints: Self.deduped(drafts.flatMap(\.keyPoints)),
            decisions: Self.deduped(drafts.flatMap(\.decisions)),
            actionItems: ActionItem.resolved(from: drafts.flatMap(\.actionItems), ownerNames: ownerNames)
        )
    }

    /// Names the owner's labels in the prompt so attribution starts from the transcript
    /// rather than the model's guess at who "I" is. The guard behind it doesn't depend
    /// on this working — but a model told which speaker is the user demotes fewer real
    /// commitments to follow-ups.
    private static func instructions(ownerNames: Set<String>) -> String {
        let ownerLabels = (["Me"] + ownerNames.sorted()).map { "[\($0)]" }.joined(separator: " or ")
        return """
            You turn meeting transcripts and the user's rough notes into clean, \
            structured meeting notes.

            Each transcript line is prefixed with a speaker label. \(ownerLabels) is the \
            user. [Them] means someone other than the user whose identity is unknown. \
            A label like [Speaker 2] means a distinct voice that could not be named — \
            do not guess who it is, and do not assume it is the user. Any other label \
            is a person's name.

            Only attribute a decision or action item to someone when their label \
            makes it clear. Otherwise say the group decided it.

            For every action item, set owner to the speaker label of whoever committed \
            to it, and set disposition to actionable only when the user committed to it \
            themselves. Anything anyone else committed to, and anything the transcript \
            does not attribute, is followUp.

            The user's rough notes indicate what they found important — weight them \
            heavily.
            """
    }

    private static func deduped(_ lines: [String]) -> [String] {
        var seen: Set<String> = []
        return lines.compactMap { line in
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, seen.insert(ActionItem.normalizedText(text)).inserted else { return nil }
            return text
        }
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

        // Split on disposition, not on who is named: the guard has already made
        // `actionable` mean "the owner committed to this themselves", so this is the
        // same line an agent routes on. Owners are shown only under Follow-ups, where
        // the name is who to chase; under Action items it would only ever be the user.
        let mine = actionItems.filter { $0.disposition == .actionable }
        let theirs = actionItems.filter { $0.disposition == .followUp }
        if !mine.isEmpty {
            out += "\n\n## Action items\n" + mine.map { "- [ ] \($0.text)" }.joined(separator: "\n")
        }
        if !theirs.isEmpty {
            out +=
                "\n\n## Follow-ups\n"
                + theirs.map { item in
                    guard let owner = item.owner else { return "- [ ] \(item.text)" }
                    return "- [ ] \(item.text) — \(owner)"
                }.joined(separator: "\n")
        }
        return out
    }
}
