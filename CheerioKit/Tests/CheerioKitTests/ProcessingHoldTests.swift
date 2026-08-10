import Foundation
import SwiftData
import Testing

@testable import CheerioKit

@Suite struct ProcessingHoldDurationTests {
    @Test func defaultIsTwoMinutes() {
        #expect(ProcessingHoldDuration.default == .twoMinutes)
    }

    @Test func offHasNoGracePeriod() {
        #expect(ProcessingHoldDuration.off.gracePeriod == nil)
        #expect(ProcessingHoldDuration.fiveMinutes.gracePeriod == 300)
    }

    @Test func offNeverHolds() {
        #expect(!ProcessingHoldDuration.off.applies(to: .meeting))
        #expect(!ProcessingHoldDuration.off.applies(to: .directive))
    }

    @Test func directivesNeverHold() {
        for duration in ProcessingHoldDuration.allCases {
            #expect(!duration.applies(to: .directive))
        }
    }

    @Test func meetingsHoldForAnyNonZeroWindow() {
        #expect(ProcessingHoldDuration.oneMinute.applies(to: .meeting))
        #expect(ProcessingHoldDuration.fifteenMinutes.applies(to: .meeting))
    }
}

/// Touches real `UserDefaults.standard` the way ``AudioRetention/current`` does —
/// save/restore per test, `.serialized` so two tests can't race the same key.
@Suite(.serialized) struct ProcessingHoldDurationDefaultsTests {
    private func withStoredSeconds(_ value: Int?, _ body: () throws -> Void) rethrows {
        let key = ProcessingHoldDuration.defaultsKey
        let previous = UserDefaults.standard.object(forKey: key) as? Int
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        try body()
    }

    @Test func unsetReadsAsTheDefault() {
        withStoredSeconds(nil) {
            #expect(ProcessingHoldDuration.current == .default)
        }
    }

    @Test func storedValueWins() {
        withStoredSeconds(ProcessingHoldDuration.off.rawValue) {
            #expect(ProcessingHoldDuration.current == .off)
        }
        withStoredSeconds(ProcessingHoldDuration.fifteenMinutes.rawValue) {
            #expect(ProcessingHoldDuration.current == .fifteenMinutes)
        }
    }

    @Test func unrecognizedValueFallsBackToTheDefault() {
        withStoredSeconds(42) {
            #expect(ProcessingHoldDuration.current == .default)
        }
    }
}

@Suite struct ProcessingHoldWindowTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func deadlineStartsOneGracePeriodOut() {
        let window = ProcessingHoldWindow(startedAt: start, gracePeriod: 120)
        #expect(window.deadline == start.addingTimeInterval(120))
        #expect(window.remaining(at: start) == 120)
        #expect(!window.isExpired(at: start))
    }

    @Test func activityRestartsTheWindowFromThatMoment() {
        var window = ProcessingHoldWindow(startedAt: start, gracePeriod: 120)
        let edit = start.addingTimeInterval(90)
        window.recordActivity(at: edit)
        #expect(window.deadline == edit.addingTimeInterval(120))
    }

    @Test func staleActivityNeverPullsTheDeadlineEarlier() {
        var window = ProcessingHoldWindow(startedAt: start, gracePeriod: 120)
        let original = window.deadline
        // A backdated event — a clock adjustment, out-of-order delivery — must
        // not shorten the time someone still editing was promised.
        window.recordActivity(at: start.addingTimeInterval(-500))
        #expect(window.deadline == original)
    }

    @Test func expiryIsTheDeadlinePassing() {
        let window = ProcessingHoldWindow(startedAt: start, gracePeriod: 60)
        #expect(!window.isExpired(at: start.addingTimeInterval(59)))
        #expect(window.isExpired(at: start.addingTimeInterval(60)))
        #expect(window.isExpired(at: start.addingTimeInterval(61)))
    }

    @Test func remainingClampsAtZero() {
        let window = ProcessingHoldWindow(startedAt: start, gracePeriod: 60)
        #expect(window.remaining(at: start.addingTimeInterval(90)) == 0)
    }
}

/// Only the pure half of ``ProcessingPlan`` lives here — everything that reads
/// the live callback settings is in `TranscriptCallbackSettingsTests` instead,
/// inside the *same* `.serialized` suite as the other tests mutating those
/// `UserDefaults` keys. A second serialized suite over the same keys wouldn't be
/// safe: `.serialized` only orders tests within one suite, and two suites still
/// run concurrently with each other.
@Suite struct ProcessingPlanTests {
    @Test func blankPromptTrimsToNil() {
        #expect(ProcessingPlan(runCallback: true, callbackPrompt: "  \n ").trimmedCallbackPrompt == nil)
        #expect(ProcessingPlan(runCallback: true, callbackPrompt: " focus on budget ").trimmedCallbackPrompt == "focus on budget")
    }
}

/// The quit-mid-holding contract, pinned against a real (in-memory) store: a
/// held meeting is exactly one whose row still carries a plan, and the recovery
/// query finds all of those and nothing else.
@Suite struct PendingProcessingRecoveryTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Meeting.self, TranscriptSegment.self, EnrolledSpeaker.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @Test func findsTheMeetingAHoldLeftBehind() throws {
        let context = try makeContext()
        let held = Meeting(title: "Held")
        held.endedAt = .now
        held.pendingProcessingPlan = ProcessingPlan(runCallback: true, callbackPrompt: "file the follow-ups")
        context.insert(held)

        let processed = Meeting(title: "Processed")
        processed.endedAt = .now
        context.insert(processed)
        try context.save()

        let pending = try Meeting.awaitingProcessing(in: context)
        #expect(pending.count == 1)
        #expect(pending.first?.title == "Held")
        #expect(pending.first?.pendingProcessingPlan?.callbackPrompt == "file the follow-ups")
    }

    @Test func claimingThePlanRemovesTheMeetingFromRecovery() throws {
        let context = try makeContext()
        let held = Meeting(title: "Held")
        held.endedAt = .now
        held.pendingProcessingPlan = ProcessingPlan(runCallback: false)
        context.insert(held)
        try context.save()

        held.pendingProcessingPlan = nil
        try context.save()

        #expect(try Meeting.awaitingProcessing(in: context).isEmpty)
    }

    @Test func aCrashMidRecordingIsNotARecoveryCandidate() throws {
        // No `endedAt`, no plan — that row belongs to
        // `StorageMigration.closeAbandonedRecordings`, and recovery must not
        // process a transcript whose recording never finished cleanly.
        let context = try makeContext()
        let crashed = Meeting(title: "Crashed")
        context.insert(crashed)
        try context.save()

        #expect(try Meeting.awaitingProcessing(in: context).isEmpty)
    }

    @Test func retentionNeverPurgesAudioAHoldStillNeeds() throws {
        // "Don't keep audio" purges everything with `endedAt` set the moment it
        // runs — and a held meeting has `endedAt` set minutes before diarization
        // reads its CAFs. The plan on the row is what keeps retention's hands
        // off until processing has consumed the audio.
        let context = try makeContext()

        let held = Meeting(title: "Held")
        held.endedAt = .now
        held.audioDirectory = "Meetings/\(UUID().uuidString)"
        held.pendingProcessingPlan = ProcessingPlan(runCallback: true)
        context.insert(held)

        let processed = Meeting(title: "Processed")
        processed.endedAt = .now
        // A path that doesn't exist on disk: `AudioStorage.removeDirectory`
        // succeeds quietly for one already gone, so this exercises the full
        // purge path without touching the real Application Support container.
        processed.audioDirectory = "Meetings/\(UUID().uuidString)"
        context.insert(processed)
        try context.save()

        let removed = try AudioRetentionService.purge(retention: .none, context: context)

        #expect(removed == 1)
        #expect(held.audioDirectory != nil)
        #expect(processed.audioDirectory == nil)

        // Once processing claims the plan, the next sweep treats it like any
        // other finished meeting.
        held.pendingProcessingPlan = nil
        try context.save()
        #expect(try AudioRetentionService.purge(retention: .none, context: context) == 1)
        #expect(held.audioDirectory == nil)
    }

    @Test func retentionHonorsTheCallersMidPipelineExclusion() throws {
        // Once processing claims a meeting, its row carries nothing that says the
        // audio is still being read — the pending plan is gone by design, so a
        // purge landing during the pipeline's awaits would delete the CAFs out
        // from under diarization. The caller's exclusion set is the only thing
        // standing in the way, which is exactly what this pins.
        let context = try makeContext()

        let midPipeline = Meeting(title: "Mid-pipeline")
        midPipeline.endedAt = .now
        midPipeline.audioDirectory = "Meetings/\(UUID().uuidString)"
        context.insert(midPipeline)
        try context.save()

        let removed = try AudioRetentionService.purge(
            retention: .none, context: context,
            excludingMeetingIDs: [midPipeline.persistentModelID])
        #expect(removed == 0)
        #expect(midPipeline.audioDirectory != nil)

        // The pipeline's own concluding purge passes an empty set for meetings it
        // has finished with — at which point the same meeting is fair game.
        #expect(try AudioRetentionService.purge(retention: .none, context: context) == 1)
        #expect(midPipeline.audioDirectory == nil)
    }

    @Test func planRoundTripsThroughTheStore() throws {
        let context = try makeContext()
        let held = Meeting(title: "Held")
        held.endedAt = .now
        held.pendingProcessingPlan = ProcessingPlan(runCallback: true, callbackPrompt: "prompt")
        context.insert(held)
        try context.save()

        // A fresh context against the same container reads the row back off the
        // store rather than out of the first context's live objects.
        let reread = ModelContext(context.container)
        let meetings = try reread.fetch(FetchDescriptor<Meeting>())
        #expect(meetings.first?.pendingProcessingPlan == ProcessingPlan(runCallback: true, callbackPrompt: "prompt"))
    }
}
