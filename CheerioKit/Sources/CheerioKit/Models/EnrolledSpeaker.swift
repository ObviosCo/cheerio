import Foundation
import SwiftData

/// A known voice, so diarization can return a name instead of "Speaker 2".
///
/// The reference audio has to be kept: Sortformer is primed by *processing* the
/// enrollment audio before each meeting, not by storing an embedding we could
/// persist instead.
@Model
public final class EnrolledSpeaker {
    public var name: String
    /// Path to the reference recording, relative to Application Support.
    public var audioPath: String
    public var enrolledAt: Date
    /// Length of the reference recording, for showing whether it's long enough.
    public var duration: TimeInterval

    public init(name: String, audioPath: String, duration: TimeInterval, enrolledAt: Date = .now) {
        self.name = name
        self.audioPath = audioPath
        self.duration = duration
        self.enrolledAt = enrolledAt
    }

    /// Below this, diarization struggles to distinguish similar voices.
    public static let recommendedDuration: TimeInterval = 20

    public var hasEnoughAudio: Bool {
        duration >= Self.recommendedDuration
    }
}
