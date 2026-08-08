import Foundation
import FoundationModels

/// Generates a short, specific title for a finished meeting from its transcript —
/// the auto-title half of issue #32. Lives beside ``SummarizationEngine`` rather
/// than inside it: titling runs once per meeting rather than per chunk, wants a
/// much smaller excerpt than notes generation, and its uniqueness prompt has
/// nothing to do with note-taking.
public actor TitleGenerator {
    public enum TitleError: Error {
        case modelUnavailable(String)
        /// The excerpt sent to the model was empty (e.g. a meeting with no
        /// transcript at all) — nothing to title from.
        case emptyTranscript
        /// Both the first draft and the one retry collided with a recent title
        /// after normalization (see ``normalize(_:)``) — issue #32's
        /// distinguishability requirement isn't met. The caller is expected to
        /// treat this the same as any other title failure and leave the
        /// timestamp placeholder standing.
        case notDistinctFromRecentTitles(String)
    }

    /// Characters of transcript shown to the model — a small fraction of
    /// ``SummarizationEngine``'s chunk budget. A title only needs to know what a
    /// meeting was about, which usually announces itself in the opening minutes;
    /// stuffing the whole transcript in would spend most of the ~4k-token context
    /// on text that doesn't change the answer, and this prompt already spends part
    /// of that budget on the recent-titles list.
    static let excerptCharacterBudget = 4_000

    /// How many recent titles to show the model, so it can steer away from them.
    static let maxRecentTitles = 10

    /// Titles longer than this are truncated — a defensive clamp against a model
    /// that ignores the length guidance in its own instructions.
    static let maxTitleLength = 80

    private let model: SystemLanguageModel

    /// - Parameter model: injected rather than reached for, same as
    ///   ``SummarizationEngine/init(model:)`` — see its doc comment for why this is
    ///   as pluggable as the framework allows today.
    public init(model: SystemLanguageModel = .default) {
        self.model = model
    }

    /// One title suggestion, straight from the model and unvetted — see
    /// ``clean(_:)`` for the deterministic cleanup applied before it's used.
    @Generable
    struct TitleDraft: Sendable {
        @Guide(
            description:
                "A short, specific meeting title (3-8 words) naming what the meeting was about. No surrounding quotation marks, no trailing punctuation."
        )
        var title: String
    }

    /// - Parameters:
    ///   - transcript: the meeting's full transcript; only the leading excerpt is
    ///     ever sent to the model.
    ///   - recentTitles: the library's most recent meeting titles, shown to the
    ///     model so it can be told to avoid them — "Weekly sync" three times in a
    ///     row fails the uniqueness requirement even if each is individually
    ///     accurate. Order doesn't matter; only the first ``maxRecentTitles`` are
    ///     used.
    public func generateTitle(transcript: String, recentTitles: [String]) async throws -> String {
        guard case .available = model.availability else {
            throw TitleError.modelUnavailable("\(model.availability)")
        }

        let excerpt = String(transcript.prefix(Self.excerptCharacterBudget))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !excerpt.isEmpty else {
            throw TitleError.emptyTranscript
        }

        let recent = Array(recentTitles.prefix(Self.maxRecentTitles))
        let session = LanguageModelSession(model: model, instructions: Self.instructions)
        let prompt = """
            Recent meeting titles — the new title must read as clearly distinct \
            from every one of these, not just a reshuffling of the same words:
            \(recent.isEmpty ? "(none yet)" : recent.map { "- \($0)" }.joined(separator: "\n"))

            Transcript excerpt:
            \(excerpt)
            """
        let response = try await session.respond(to: prompt, generating: TitleDraft.self)
        var title = Self.clean(response.content.title)

        // The prompt only *asks* the model to steer away from `recent` — nothing
        // stops it from ignoring that and handing back "Weekly sync" again, which
        // would fail issue #32's distinguishability requirement outright. Catch
        // that deterministically rather than trusting the instructions to hold,
        // and give the model one more shot with the exact collision named before
        // giving up.
        if Self.collides(title, withAnyOf: recent) {
            let retryPrompt = """
                You already suggested "\(title)", which duplicates an existing \
                title — produce a clearly different one.
                """
            let retryResponse = try await session.respond(to: retryPrompt, generating: TitleDraft.self)
            title = Self.clean(retryResponse.content.title)

            if Self.collides(title, withAnyOf: recent) {
                throw TitleError.notDistinctFromRecentTitles(title)
            }
        }

        return title
    }

    private static let instructions = """
        You read the start of a meeting transcript and give it a short, specific \
        title, the way a person would rename a calendar event afterward. Prefer \
        naming the topic, project, or people involved over generic words like \
        "Meeting", "Call", or "Sync" on their own. Never reuse or lightly reword \
        one of the recent titles you're given — the point is to be able to tell \
        this meeting apart from them at a glance.
        """

    /// Deterministic cleanup around the model call: trims whitespace, collapses
    /// embedded newlines, strips one surrounding pair of quote characters (models
    /// wrap titles in quotes far more often than the schema's guidance discourages
    /// it), drops a lone trailing period, and clamps length so a runaway response
    /// can't land verbatim in the library.
    static func clean(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")

        let quotePairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("“", "”"), ("‘", "’")]
        for (open, close) in quotePairs {
            if title.count >= 2, title.first == open, title.last == close {
                title = String(title.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        if title.hasSuffix(".") {
            title = String(title.dropLast())
        }

        if title.count > maxTitleLength {
            title = String(title.prefix(maxTitleLength))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return title
    }

    /// The collision key for the distinguishability check: case, spacing, and
    /// punctuation are all things the model varies between attempts while
    /// meaning the same title. Same normalization discipline as
    /// ``ActionItem/normalizedText(_:)``, reimplemented locally rather than
    /// reused — a title generator has no business depending on the action-item
    /// model.
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .joined(separator: " ")
    }

    /// Whether `title` is, after normalization, the same as any title already
    /// in `recentTitles` — the deterministic half of issue #32's
    /// distinguishability requirement. Empty titles never collide: an empty
    /// string means the model returned nothing usable, a different failure
    /// this function isn't meant to catch.
    static func collides(_ title: String, withAnyOf recentTitles: [String]) -> Bool {
        guard !title.isEmpty else { return false }
        let normalizedTitle = normalize(title)
        return recentTitles.contains { normalize($0) == normalizedTitle }
    }
}
