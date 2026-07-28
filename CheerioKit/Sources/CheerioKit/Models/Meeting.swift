import Foundation
import SwiftData

/// Which capture channel a transcript segment came from.
public enum SpeakerChannel: String, Codable, Sendable {
    /// Microphone — the user.
    case me
    /// System audio — everyone else on the call.
    case them
}

@Model
public final class Meeting {
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    /// EventKit event identifier, if this meeting was linked to a calendar event.
    public var calendarEventID: String?
    /// The user's rough notes, typed during the meeting.
    public var roughNotes: String
    /// AI-enhanced notes (Markdown), generated after the meeting.
    public var enhancedNotes: String?
    /// Path to the recorded audio files, relative to Application Support. Nil once purged.
    public var audioDirectory: String?

    @Relationship(deleteRule: .cascade, inverse: \TranscriptSegment.meeting)
    public var segments: [TranscriptSegment] = []

    public init(title: String, startedAt: Date = .now, calendarEventID: String? = nil) {
        self.title = title
        self.startedAt = startedAt
        self.calendarEventID = calendarEventID
        self.roughNotes = ""
    }

    /// Full transcript in chronological order, formatted for display or summarization.
    public var transcriptText: String {
        segments
            .sorted { $0.startTime < $1.startTime }
            .map { "[\($0.channel == .me ? "Me" : "Them")] \($0.text)" }
            .joined(separator: "\n")
    }
}

@Model
public final class TranscriptSegment {
    public var channelRaw: String
    public var text: String
    /// Seconds from meeting start.
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var meeting: Meeting?

    public var channel: SpeakerChannel {
        SpeakerChannel(rawValue: channelRaw) ?? .them
    }

    public init(channel: SpeakerChannel, text: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.channelRaw = channel.rawValue
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
    }
}
