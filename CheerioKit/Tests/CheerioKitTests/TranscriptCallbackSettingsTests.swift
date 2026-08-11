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
        try body()
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
}
