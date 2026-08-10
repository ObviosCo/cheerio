import Foundation
import SwiftData

/// What the user decided, during the post-meeting holding state (issue #136),
/// about how this one meeting should be processed — the pending-inputs model the
/// holding UI edits and the processing pipeline consumes.
///
/// Persisted on ``Meeting/pendingProcessingPlan`` for exactly as long as the
/// meeting is held, which is what makes the holding state crash-safe: a quit or
/// crash mid-hold leaves the plan on disk, and the next launch processes the
/// meeting with it (see ``Meeting/awaitingProcessing(in:)``).
///
/// The seam for issue #137 (multiple callback triggers) is here, deliberately:
/// "which trigger to run, with what extra prompt" is per-meeting data this struct
/// already carries half of. When triggers become plural, this grows a trigger
/// identifier next to ``callbackPrompt`` rather than the pipeline growing a second
/// channel for the same decision.
public struct ProcessingPlan: Codable, Sendable, Equatable {
    /// Whether the transcript-ready callback fires for this meeting. A per-meeting
    /// override of the global scope setting — see
    /// ``TranscriptCallbackSettings/shouldFire(for:plan:)``, where the command's
    /// existence still gates: a "yes" here can't run a command nobody configured.
    public var runCallback: Bool
    /// An additional, per-meeting prompt for the callback command — the one input
    /// the global command string can't carry, since it's the same for every
    /// meeting. Delivered as `CHEERIO_ADDITIONAL_PROMPT` in the command's
    /// environment (see `CallbackPayload`); blank means none.
    public var callbackPrompt: String

    public init(runCallback: Bool, callbackPrompt: String = "") {
        self.runCallback = runCallback
        self.callbackPrompt = callbackPrompt
    }

    /// The prompt as the callback should receive it, or nil when it's blank —
    /// whitespace someone typed and deleted isn't a prompt, and the environment
    /// variable should be absent rather than empty so a command can test for it.
    public var trimmedCallbackPrompt: String? {
        let trimmed = callbackPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// What the holding state starts from: the callback fires exactly when it
    /// would have without a holding state — command configured, scope includes
    /// this kind — so a user who touches nothing gets today's behavior, and the
    /// toggle they see reflects what will actually happen rather than a blank
    /// default they'd have to reconstruct from Settings.
    public static func makeDefault(for kind: MeetingKind) -> ProcessingPlan {
        ProcessingPlan(runCallback: TranscriptCallbackSettings.shouldFire(for: kind))
    }
}

extension Meeting {
    /// Meetings a previous run left in the holding state — the app quit or crashed
    /// while one sat waiting for input. The plan on the row is the recovery
    /// contract: it only exists between entering the hold and processing being
    /// claimed, so any row still carrying one was never processed.
    ///
    /// `endedAt != nil` in the predicate is safe to rely on, not just an
    /// optimization: the plan is only ever assigned in the same synchronous stretch
    /// that sets `endedAt`, so a plan on a still-open row can't exist. A crash
    /// mid-*recording* leaves neither, and stays
    /// `StorageMigration.closeAbandonedRecordings`' problem, exactly as before.
    ///
    /// The composite plan itself is filtered in memory — `#Predicate` can't reach
    /// into an optional composite attribute — which is fine for a query that runs
    /// once per launch over the finished-meetings set.
    public static func awaitingProcessing(in context: ModelContext) throws -> [Meeting] {
        try context
            .fetch(FetchDescriptor<Meeting>(predicate: #Predicate { $0.endedAt != nil }))
            .filter { $0.pendingProcessingPlan != nil }
    }
}
