import Foundation
import Testing

@testable import CheerioKit

@Suite struct TranscriptCallbackScopeTests {
    @Test func allRecordingsIncludesBothKinds() {
        #expect(TranscriptCallbackScope.allRecordings.includes(.meeting))
        #expect(TranscriptCallbackScope.allRecordings.includes(.directive))
    }

    @Test func directivesOnlyExcludesMeetings() {
        #expect(!TranscriptCallbackScope.directivesOnly.includes(.meeting))
        #expect(TranscriptCallbackScope.directivesOnly.includes(.directive))
    }

    @Test func defaultIsAllRecordings() {
        #expect(TranscriptCallbackScope.default == .allRecordings)
    }
}

/// These touch real `UserDefaults.standard`, like ``AudioRetention/current``
/// already does — each test restores whatever was there before it ran, so this
/// suite can't leak state into another test or a real app run on the same
/// machine. `.serialized` because Swift Testing otherwise runs this suite's tests
/// concurrently, and two tests mutating the same `UserDefaults` keys at once is a
/// race no amount of save/restore in each individual test fixes.
@Suite(.serialized) struct TranscriptCallbackSettingsTests {
    /// Also clears (and restores) the trigger-list blob: `command` now reads
    /// *through* the triggers, so a stray blob left by a real app run on this
    /// machine would otherwise outrank the legacy key every one of these tests
    /// sets.
    private func withCommand(_ value: String?, _ body: () throws -> Void) rethrows {
        let key = TranscriptCallbackSettings.commandDefaultsKey
        let previous = UserDefaults.standard.string(forKey: key)
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
        try withTriggersData(nil, body)
    }

    /// Save/restore for the raw trigger blob. Takes `Data?`, not
    /// `[CallbackTrigger]?`, so tests can also stage "no blob at all" and
    /// restore whatever a real machine had byte-for-byte.
    private func withTriggersData(_ value: Data?, _ body: () throws -> Void) rethrows {
        let key = TranscriptCallbackSettings.triggersDefaultsKey
        let previous = UserDefaults.standard.data(forKey: key)
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

    private func withTriggers(_ triggers: [CallbackTrigger], _ body: () throws -> Void) throws {
        try withTriggersData(JSONEncoder().encode(triggers), body)
    }

    private func withScope(_ value: TranscriptCallbackScope, _ body: () throws -> Void) rethrows {
        let key = TranscriptCallbackScope.defaultsKey
        let previous = UserDefaults.standard.object(forKey: key) as? Int
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.set(value.rawValue, forKey: key)
        try body()
    }

    @Test func unsetCommandIsDisabled() {
        withCommand(nil) {
            #expect(TranscriptCallbackSettings.command == nil)
            #expect(!TranscriptCallbackSettings.shouldFire(for: .meeting))
        }
    }

    @Test func blankCommandIsDisabledEvenWhenSet() {
        withCommand("   \n") {
            #expect(TranscriptCallbackSettings.command == nil)
        }
    }

    @Test func configuredCommandIsTrimmed() {
        withCommand("  claude -p 'go' \n") {
            #expect(TranscriptCallbackSettings.command == "claude -p 'go'")
        }
    }

    @Test func shouldFireRespectsScope() {
        withCommand("claude -p go") {
            withScope(.directivesOnly) {
                #expect(!TranscriptCallbackSettings.shouldFire(for: .meeting))
                #expect(TranscriptCallbackSettings.shouldFire(for: .directive))
            }
            withScope(.allRecordings) {
                #expect(TranscriptCallbackSettings.shouldFire(for: .meeting))
                #expect(TranscriptCallbackSettings.shouldFire(for: .directive))
            }
        }
    }

    // The `ProcessingPlan` cases below live in this suite, not next to the plan's
    // own tests, because they read and write these same two keys — and
    // `.serialized` only orders tests *within* a suite, so a second suite over
    // the same keys would still race this one.

    @Test func defaultPlanMirrorsWhatWouldHaveFiredAnyway() {
        withCommand("claude -p go") {
            withScope(.allRecordings) {
                #expect(ProcessingPlan.makeDefault(for: .meeting).runCallback)
                #expect(ProcessingPlan.makeDefault(for: .meeting).callbackPrompt.isEmpty)
            }
            withScope(.directivesOnly) {
                #expect(!ProcessingPlan.makeDefault(for: .meeting).runCallback)
            }
        }
        withCommand(nil) {
            withScope(.allRecordings) {
                #expect(!ProcessingPlan.makeDefault(for: .meeting).runCallback)
            }
        }
    }

    @Test func planOverridesTheScopeInBothDirections() {
        withCommand("claude -p go") {
            withScope(.directivesOnly) {
                // The user said yes during the hold; the scope's "no" doesn't outrank them.
                #expect(TranscriptCallbackSettings.shouldFire(for: .meeting, plan: ProcessingPlan(runCallback: true)))
            }
            withScope(.allRecordings) {
                // And their "no" holds against a scope that would have fired.
                #expect(!TranscriptCallbackSettings.shouldFire(for: .meeting, plan: ProcessingPlan(runCallback: false)))
            }
        }
    }

    @Test func nilPlanIsTheZeroTouchPathAndDefersToTheScope() {
        withCommand("claude -p go") {
            withScope(.directivesOnly) {
                #expect(!TranscriptCallbackSettings.shouldFire(for: .meeting, plan: nil))
                #expect(TranscriptCallbackSettings.shouldFire(for: .directive, plan: nil))
            }
        }
    }

    @Test func noCommandMeansNoFireWhateverThePlanSays() {
        withCommand(nil) {
            withScope(.allRecordings) {
                #expect(!TranscriptCallbackSettings.shouldFire(for: .meeting, plan: ProcessingPlan(runCallback: true)))
            }
        }
    }

    // Migration (#137): the pre-existing single command must come back as the
    // sole, default trigger — nobody's configured callback disappears on
    // upgrade.

    @Test func legacyCommandBecomesTheSoleDefaultTrigger() {
        withCommand("  claude -p 'go' \n") {
            let triggers = TranscriptCallbackSettings.triggers
            #expect(triggers.count == 1)
            #expect(triggers.first?.command == "claude -p 'go'")
            #expect(triggers.first?.isDefault == true)
            #expect(triggers.first?.name == "Default")
            #expect(TranscriptCallbackSettings.command == "claude -p 'go'")
        }
    }

    @Test func legacyMigrationIsStableAcrossReads() {
        // The synthesis is pure, so the fixed id is what lets a plan stash the
        // migrated trigger's id during a hold and still resolve it at fire time.
        withCommand("claude -p go") {
            #expect(TranscriptCallbackSettings.triggers.first?.id == TranscriptCallbackSettings.migratedTriggerID)
            #expect(TranscriptCallbackSettings.triggers.first?.id == TranscriptCallbackSettings.migratedTriggerID)
        }
    }

    @Test func blankLegacyCommandMigratesToNoTriggers() {
        withCommand("   \n") {
            #expect(TranscriptCallbackSettings.triggers.isEmpty)
            #expect(TranscriptCallbackSettings.defaultTrigger == nil)
        }
    }

    @Test func storedTriggersOutrankTheLegacyCommand() throws {
        try withCommand("old-command") {
            try withTriggers([CallbackTrigger(name: "Repo agent", command: "claude -p new", isDefault: true)]) {
                #expect(TranscriptCallbackSettings.triggers.count == 1)
                #expect(TranscriptCallbackSettings.command == "claude -p new")
            }
        }
    }

    @Test func savingTriggersMirrorsTheDefaultToTheLegacyKey() {
        withCommand(nil) {
            let triage = CallbackTrigger(name: "Triage", command: "triage.sh")
            let repo = CallbackTrigger(name: "Repo", command: "claude -p repo", isDefault: true)
            TranscriptCallbackSettings.triggers = [triage, repo]
            #expect(UserDefaults.standard.string(forKey: TranscriptCallbackSettings.commandDefaultsKey) == "claude -p repo")
            #expect(TranscriptCallbackSettings.triggers == [triage, repo])

            TranscriptCallbackSettings.triggers = []
            #expect(UserDefaults.standard.string(forKey: TranscriptCallbackSettings.commandDefaultsKey) == nil)
            #expect(TranscriptCallbackSettings.triggers.isEmpty)
        }
    }

    @Test func savingRestoresTheSingleDefaultInvariant() {
        withCommand(nil) {
            TranscriptCallbackSettings.triggers = [
                CallbackTrigger(name: "A", command: "a"),
                CallbackTrigger(name: "B", command: "b"),
            ]
            #expect(TranscriptCallbackSettings.triggers.filter(\.isDefault).count == 1)
            #expect(TranscriptCallbackSettings.defaultTrigger?.name == "A")
        }
    }

    // Per-meeting trigger choice (#137): resolution and its gates.

    @Test func planChoosesItsTriggerAndNilMeansTheDefault() throws {
        let repo = CallbackTrigger(name: "Repo", command: "claude -p repo", isDefault: true)
        let triage = CallbackTrigger(name: "Triage", command: "triage.sh")
        try withCommand(nil) {
            try withTriggers([repo, triage]) {
                #expect(TranscriptCallbackSettings.trigger(for: ProcessingPlan(runCallback: true, triggerID: triage.id)) == triage)
                #expect(TranscriptCallbackSettings.trigger(for: ProcessingPlan(runCallback: true)) == repo)
                #expect(TranscriptCallbackSettings.trigger(for: nil) == repo)
            }
        }
    }

    @Test func aDeletedTriggerFallsBackToTheDefault() throws {
        let repo = CallbackTrigger(name: "Repo", command: "claude -p repo", isDefault: true)
        try withCommand(nil) {
            try withTriggers([repo]) {
                let plan = ProcessingPlan(runCallback: true, triggerID: UUID())
                #expect(TranscriptCallbackSettings.trigger(for: plan) == repo)
                withScope(.directivesOnly) {
                    // The fallback keeps the user's "yes" runnable, so the fire
                    // decision holds too.
                    #expect(TranscriptCallbackSettings.shouldFire(for: .meeting, plan: plan))
                }
            }
        }
    }

    @Test func aChosenTriggerWithABlankCommandDoesNotFire() throws {
        // Deliberately *not* the deleted-trigger fallback: silently running a
        // different command than the one chosen would be worse than not firing.
        let repo = CallbackTrigger(name: "Repo", command: "claude -p repo", isDefault: true)
        let blank = CallbackTrigger(name: "Half-typed", command: "  ")
        try withCommand(nil) {
            try withTriggers([repo, blank]) {
                withScope(.allRecordings) {
                    let plan = ProcessingPlan(runCallback: true, triggerID: blank.id)
                    #expect(TranscriptCallbackSettings.trigger(for: plan) == blank)
                    #expect(!TranscriptCallbackSettings.shouldFire(for: .meeting, plan: plan))
                }
            }
        }
    }

    @Test func hasRunnableTriggerLooksPastTheDefault() throws {
        // A blank default with a usable second trigger still counts: the holding
        // UI's trigger choice has to be offered whenever *some* trigger could run.
        let blankDefault = CallbackTrigger(name: "Default", command: " ", isDefault: true)
        let triage = CallbackTrigger(name: "Triage", command: "triage.sh")
        try withCommand(nil) {
            try withTriggers([blankDefault, triage]) {
                #expect(TranscriptCallbackSettings.command == nil)
                #expect(TranscriptCallbackSettings.hasRunnableTrigger)
            }
            try withTriggers([blankDefault]) {
                #expect(!TranscriptCallbackSettings.hasRunnableTrigger)
            }
        }
    }
}

/// Pure list invariants — no `UserDefaults` anywhere, so this suite can run
/// concurrently with everything.
@Suite struct CallbackTriggerTests {
    @Test func normalizingAnEmptyListStaysEmpty() {
        #expect([CallbackTrigger]().normalized().isEmpty)
    }

    @Test func normalizingPromotesTheFirstWhenNoneIsDefault() {
        let normalized = [
            CallbackTrigger(name: "A", command: "a"),
            CallbackTrigger(name: "B", command: "b"),
        ].normalized()
        #expect(normalized.map(\.isDefault) == [true, false])
    }

    @Test func normalizingKeepsTheFirstMarkedDefaultAndClearsTheRest() {
        let normalized = [
            CallbackTrigger(name: "A", command: "a"),
            CallbackTrigger(name: "B", command: "b", isDefault: true),
            CallbackTrigger(name: "C", command: "c", isDefault: true),
        ].normalized()
        #expect(normalized.map(\.isDefault) == [false, true, false])
    }

    @Test func settingDefaultMovesTheMark() {
        let a = CallbackTrigger(name: "A", command: "a", isDefault: true)
        let b = CallbackTrigger(name: "B", command: "b")
        let updated = [a, b].settingDefault(b.id)
        #expect(updated.map(\.isDefault) == [false, true])
    }

    @Test func settingDefaultToAnUnknownIDChangesNothing() {
        let a = CallbackTrigger(name: "A", command: "a", isDefault: true)
        let b = CallbackTrigger(name: "B", command: "b")
        #expect([a, b].settingDefault(UUID()) == [a, b])
    }

    @Test func removingTheDefaultHandsTheRoleToTheFirstRemaining() {
        let a = CallbackTrigger(name: "A", command: "a", isDefault: true)
        let b = CallbackTrigger(name: "B", command: "b")
        let c = CallbackTrigger(name: "C", command: "c")
        let updated = [a, b, c].removing(a.id)
        #expect(updated.map(\.id) == [b.id, c.id])
        #expect(updated.map(\.isDefault) == [true, false])
    }

    @Test func removingANonDefaultLeavesTheDefaultAlone() {
        let a = CallbackTrigger(name: "A", command: "a", isDefault: true)
        let b = CallbackTrigger(name: "B", command: "b")
        let updated = [a, b].removing(b.id)
        #expect(updated == [a])
        #expect(updated.first?.isDefault == true)
    }

    @Test func blankCommandsAndNamesReadAsAbsent() {
        let trigger = CallbackTrigger(name: "  ", command: " \n")
        #expect(trigger.trimmedCommand == nil)
        #expect(trigger.displayName == "Untitled trigger")
        #expect(CallbackTrigger(name: " Repo ", command: " x ").trimmedCommand == "x")
    }
}
