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

    /// Case-insensitive match across everything the user might remember about a
    /// meeting: its name, what they jotted, the notes, and what was said.
    public func matches(_ query: String) -> Bool {
        let haystack = [title, roughNotes, enhancedNotes ?? "", transcriptText]
        return haystack.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    /// Full transcript in chronological order, formatted for display or summarization.
    ///
    /// Uses diarized speaker labels when available, falling back to the capture
    /// channel for meetings recorded before diarization ran.
    public var transcriptText: String {
        segments
            .sorted { $0.startTime < $1.startTime }
            .map { "[\($0.displayLabel)] \($0.text)" }
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
    /// Who spoke, once diarization has run. Nil until then, and nil for meetings
    /// recorded before diarization existed.
    public var speakerLabel: String?
    public var meeting: Meeting?

    public var channel: SpeakerChannel {
        SpeakerChannel(rawValue: channelRaw) ?? .them
    }

    /// Who to show as the speaker: the diarized label if we have one, otherwise the
    /// capture channel.
    public var displayLabel: String {
        speakerLabel ?? (channel == .me ? "Me" : "Them")
    }

    public init(channel: SpeakerChannel, text: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.channelRaw = channel.rawValue
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
    }
}
