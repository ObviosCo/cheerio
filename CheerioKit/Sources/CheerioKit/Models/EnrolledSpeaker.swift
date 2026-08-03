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
    /// Marks your own voice. You're in every meeting you record, so this one is
    /// selected by default and kept first if the speaker cap has to drop someone.
    public var isMe: Bool = false

    public init(name: String, audioPath: String, duration: TimeInterval, enrolledAt: Date = .now) {
        self.name = name
        self.audioPath = audioPath
        self.duration = duration
        self.enrolledAt = enrolledAt
    }

    /// Below this, diarization struggles to distinguish similar voices.
    ///
    /// Raised from 20s on 2026-08-03: a 23.6s sample still let Sortformer split that
    /// person across two speaker slots mid-meeting, while the 26.5s and 27.8s samples
    /// held. 20s was measurably too optimistic.
    public static let recommendedDuration: TimeInterval = 30

    public var hasEnoughAudio: Bool {
        duration >= Self.recommendedDuration
    }
}
