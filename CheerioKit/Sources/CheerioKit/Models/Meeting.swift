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
    /// Which enrolled voices were in this meeting, by name.
    ///
    /// Nil means nobody has said, which is not the same as `[]` — an empty roster is
    /// the right answer for an all-remote call, where priming anyone is pointless
    /// because the mic/system split already separates you from them.
    public var participantNames: [String]?

    @Relationship(deleteRule: .cascade, inverse: \TranscriptSegment.meeting)
    public var segments: [TranscriptSegment] = []

    public init(title: String, startedAt: Date = .now, calendarEventID: String? = nil) {
        self.title = title
        self.startedAt = startedAt
        self.calendarEventID = calendarEventID
        self.roughNotes = ""
    }

    /// Case-insensitive match across everything the user might remember about a
    /// meeting: its name, what they jotted, the notes, who spoke, and what was said.
    public func matches(_ query: String) -> Bool {
        let fields = [title, roughNotes, enhancedNotes ?? ""]
        if fields.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return true }

        // Segments directly rather than `transcriptText`: that sorts every segment and
        // builds the entire transcript as one string, on every keystroke. This also
        // stops "me" from matching every meeting through the "[Me] " label prefix,
        // while still finding meetings by a diarized speaker's name.
        return segments.contains {
            $0.text.localizedCaseInsensitiveContains(query)
                || $0.speakerLabel?.localizedCaseInsensitiveContains(query) == true
        }
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
    /// Set when a person named this line rather than the diarizer. Re-identifying
    /// speakers leaves these alone — a human correction outranks the model, and
    /// losing it to a later re-run would make correcting anything pointless.
    public var isSpeakerLabelManual: Bool = false
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

    /// Names this line by hand. Passing nil reverts it to the capture channel and
    /// hands it back to the diarizer.
    public func assignSpeaker(_ label: String?) {
        speakerLabel = label
        isSpeakerLabelManual = label != nil
    }

    /// True for labels the diarizer invented, like "Speaker 2".
    ///
    /// These are numbered per diarization run and we run once per channel, so
    /// "Speaker 1" from the mic and "Speaker 1" from the system tap are *different
    /// people*. Anything else — an enrolled name, a hand-typed one — does mean the
    /// same person whichever channel it turns up on.
    public static func isDiarizerGeneratedLabel(_ label: String?) -> Bool {
        guard let label, label.hasPrefix("Speaker ") else { return false }
        let number = label.dropFirst("Speaker ".count)
        return !number.isEmpty && number.allSatisfy(\.isNumber)
    }
}

/// One speaker as they appear in a single meeting, keyed by the label shown on their
/// lines — which may be an enrolled name, a "Speaker 2", or a bare channel fallback.
public struct SpeakerSummary: Identifiable, Sendable, Equatable {
    public let label: String
    /// Set when `label` is one the diarizer invented, because those are only
    /// meaningful within the channel they came from — see
    /// ``TranscriptSegment/isDiarizerGeneratedLabel(_:)``. Nil for real names, which
    /// identify the same person on either channel and so should merge.
    public let scopedChannel: SpeakerChannel?
    public let lineCount: Int
    public let duration: TimeInterval
    /// The channel most of this speaker's audio came from, i.e. which CAF to excerpt.
    public let channel: SpeakerChannel
    /// True when every line under this label was named by hand.
    public let isManual: Bool

    public var id: String {
        // Unit separator: can't occur in a label, so it can't collide.
        scopedChannel.map { "\(label)\u{1F}\($0.rawValue)" } ?? label
    }

    /// What to show. Two unrelated "Speaker 1"s need telling apart, and where they
    /// were sitting is the useful distinction.
    public var displayName: String {
        guard let scopedChannel else { return label }
        return "\(label) · \(scopedChannel == .me ? "in room" : "remote")"
    }

    /// Whether this segment is one of the lines this summary covers.
    public func matches(_ segment: TranscriptSegment) -> Bool {
        guard segment.displayLabel == label else { return false }
        guard let scopedChannel else { return true }
        return segment.channel == scopedChannel
    }
}

extension Meeting {
    /// The distinct speakers in this meeting, most talkative first.
    ///
    /// Grouped by `displayLabel` rather than `speakerLabel` so a meeting that was
    /// never diarized still lists its "Me"/"Them" speakers and can be corrected.
    ///
    /// Diarizer-generated labels are additionally scoped to their channel: the two
    /// channels are diarized independently, so merging the mic's "Speaker 1" with the
    /// system tap's would fuse two unrelated people into one row — and then rename
    /// both of them together.
    public var speakerSummaries: [SpeakerSummary] {
        struct Key: Hashable {
            let label: String
            let channel: SpeakerChannel?
        }

        var order: [Key] = []
        var grouped: [Key: [TranscriptSegment]] = [:]
        for segment in segments {
            let scoped = TranscriptSegment.isDiarizerGeneratedLabel(segment.speakerLabel)
                ? segment.channel
                : nil
            let key = Key(label: segment.displayLabel, channel: scoped)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(segment)
        }

        return order.compactMap { key -> SpeakerSummary? in
            guard let group = grouped[key] else { return nil }
            let duration = group.reduce(0) { $0 + max(0, $1.endTime - $1.startTime) }
            // Whichever channel carries more of this speaker is the one to excerpt from.
            let meSeconds = group.filter { $0.channel == .me }
                .reduce(0) { $0 + max(0, $1.endTime - $1.startTime) }
            return SpeakerSummary(
                label: key.label,
                scopedChannel: key.channel,
                lineCount: group.count,
                duration: duration,
                channel: key.channel ?? (meSeconds * 2 >= duration ? .me : .them),
                isManual: group.allSatisfy(\.isSpeakerLabelManual)
            )
        }
        .sorted { $0.duration > $1.duration }
    }

    /// Renames every line this speaker is on. Passing nil for `newLabel` reverts them
    /// to the capture channel. Returns how many lines changed.
    ///
    /// This is the fix for the diarizer splitting one person across two slots: the
    /// phantom's lines get merged into the real speaker in one move. Takes a summary
    /// rather than a bare label so a channel-scoped "Speaker 1" only renames its own
    /// channel's lines.
    @discardableResult
    public func relabelSpeaker(_ speaker: SpeakerSummary, to newLabel: String?) -> Int {
        var changed = 0
        for segment in segments where speaker.matches(segment) {
            segment.assignSpeaker(newLabel)
            changed += 1
        }
        return changed
    }

    /// The enrolled voices to prime for this meeting, and anyone the diarizer's cap
    /// forced out.
    ///
    /// Sortformer resolves at most `limit` speakers and every primed voice consumes one
    /// of them, so priming someone who wasn't in the room costs a slot a real
    /// participant needed — that's the whole reason a per-meeting roster exists rather
    /// than "the first four enrolled". `dropped` is returned instead of silently
    /// truncating, so callers can say who got left out.
    /// Pass the channel being diarized so the cap is spent on voices that could
    /// actually appear on it. Nil asks for the roster as a whole, for display.
    public func participants(
        from enrolled: [EnrolledSpeaker],
        channel: SpeakerChannel? = nil,
        limit: Int
    ) -> (chosen: [EnrolledSpeaker], dropped: [EnrolledSpeaker]) {
        let selected: [EnrolledSpeaker]
        if let participantNames {
            let wanted = Set(participantNames)
            selected = enrolled.filter { wanted.contains($0.name) }
        } else {
            // Nobody has chosen yet, so behave as the app did before rosters existed.
            selected = enrolled
        }

        // You can't be on the far end of your own call, so your voice isn't a candidate
        // for the system tap at all. Dropping it *before* the cap matters: capping first
        // and filtering after would leave that channel priming three voices while a
        // real remote participant sat in `dropped`.
        let candidates = channel == .them ? selected.filter { !$0.isMe } : selected

        // Partition rather than sort: `sorted` isn't stable, and enrollment order is
        // the only ordering the rest of the roster has.
        let ordered = candidates.filter(\.isMe) + candidates.filter { !$0.isMe }
        return (Array(ordered.prefix(limit)), Array(ordered.dropFirst(limit)))
    }

    /// The time ranges to excerpt for one speaker, for building an enrollment sample.
    public func ranges(for speaker: SpeakerSummary) -> [AudioExcerpt.Range] {
        segments
            .filter { speaker.matches($0) && $0.channel == speaker.channel }
            .map { AudioExcerpt.Range(start: $0.startTime, end: $0.endTime) }
    }
}
