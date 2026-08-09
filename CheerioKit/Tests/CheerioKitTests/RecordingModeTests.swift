import Foundation
import Testing

@testable import CheerioKit

@Suite struct RecordingModeEchoCancellationTests {
    @Test func inPersonLeavesEchoCancellationOff() {
        #expect(!RecordingMode.inPerson.echoCancellationEnabled)
    }

    @Test func videoCallTurnsEchoCancellationOn() {
        #expect(RecordingMode.videoCall.echoCancellationEnabled)
    }

    @Test func defaultIsInPerson() {
        // In-person is today's already-verified behavior; video-call's echo
        // cancellation ships opt-in until a live A/B backs closing #5.
        #expect(RecordingMode.default == .inPerson)
    }
}

/// Touches real `UserDefaults.standard`, like ``AudioRetention``'s own tests do — each test
/// restores whatever was there before it ran. `.serialized` because Swift Testing otherwise
/// runs this suite's tests concurrently, and two tests mutating the same `UserDefaults` key at
/// once is a race no amount of save/restore in each individual test fixes.
@Suite(.serialized) struct RecordingModePersistenceTests {
    private func withStored(_ value: RecordingMode?, _ body: () throws -> Void) rethrows {
        let key = RecordingMode.defaultsKey
        let previous = UserDefaults.standard.object(forKey: key) as? Int
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        if let value {
            UserDefaults.standard.set(value.rawValue, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        try body()
    }

    @Test func unsetFallsBackToDefault() {
        withStored(nil) {
            #expect(RecordingMode.current == .inPerson)
        }
    }

    @Test func storedValueRoundTrips() {
        withStored(.videoCall) {
            #expect(RecordingMode.current == .videoCall)
        }
        withStored(.inPerson) {
            #expect(RecordingMode.current == .inPerson)
        }
    }

    @Test func garbageValueFallsBackToDefault() {
        // Guards against a future case insertion shifting what an old raw value means —
        // an unrecognized int should read as "no preference", not crash or misresolve.
        let key = RecordingMode.defaultsKey
        let previous = UserDefaults.standard.object(forKey: key) as? Int
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.set(99, forKey: key)
        #expect(RecordingMode.current == .inPerson)
    }
}
