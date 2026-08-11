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
/// "Which trigger to run, with what extra prompt" is per-meeting data, so it
/// travels here (issue #137) rather than the pipeline growing a second channel
/// for the same decision — exactly the seam this struct was built to carry.
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
    /// Which configured trigger runs — a ``CallbackTrigger/id`` — or nil for
    /// whatever the default trigger is at fire time. Resolution, including the
    /// fallback when the chosen trigger was deleted mid-hold, is
    /// ``TranscriptCallbackSettings/trigger(for:)``'s.
    ///
    /// Optional with a nil default, and both halves matter for migration: plans
    /// persisted before this field existed — including crash-recovery rows still
    /// on disk from an older build — decode without it, and the flattened
    /// composite attribute migrates additively as NULL, the same story as
    /// ``Meeting/pendingProcessingPlan`` itself.
    public var triggerID: UUID?

    public init(runCallback: Bool, callbackPrompt: String = "", triggerID: UUID? = nil) {
        self.runCallback = runCallback
        self.callbackPrompt = callbackPrompt
        self.triggerID = triggerID
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
