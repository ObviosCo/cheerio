import Foundation

/// A process-independent, `Codable` snapshot of a finished meeting.
///
/// This is the one representation the transcript-ready callback and the MCP server
/// both serialize — defined once, here, so they can't quietly drift apart. Once the
/// callback ships this is API: field names, optionality, and date formatting are
/// fixed by the JSON fixture test in `MeetingExportTests`, not by whatever
/// `Codable`'s defaults happen to produce.
public struct MeetingExport: Codable, Sendable, Equatable {
    /// One transcript line, in the shape external consumers get it — not the
    /// `TranscriptSegment` model, which carries SwiftData relationships and manual-edit
    /// bookkeeping that isn't theirs to see.
    public struct Segment: Codable, Sendable, Equatable {
        public let displayLabel: String
        public let channel: SpeakerChannel
        public let startTime: TimeInterval
        public let endTime: TimeInterval
        public let text: String
        /// Whether this line is attributed to the meeting's owner — see
        /// ``Meeting/isOwnerAttributed(_:ownerNames:)``.
        public let isOwner: Bool

        public init(
            displayLabel: String,
            channel: SpeakerChannel,
            startTime: TimeInterval,
            endTime: TimeInterval,
            text: String,
            isOwner: Bool
        ) {
            self.displayLabel = displayLabel
            self.channel = channel
            self.startTime = startTime
            self.endTime = endTime
            self.text = text
            self.isOwner = isOwner
        }
    }

    public let uuid: UUID
    public let title: String
    public let kind: MeetingKind
    public let startedAt: Date
    public let endedAt: Date?
    public let participantNames: [String]?
    public let roughNotes: String
    public let enhancedNotes: String?
    /// The action items as structure, so a consumer routes on `isOwner` and
    /// `disposition` instead of parsing them back out of ``enhancedNotes``' Markdown.
    public let actionItems: [ActionItem]
    public let segments: [Segment]

    /// Builds the snapshot from a live `Meeting`.
    ///
    /// - Parameter ownerNames: enrolled `isMe` speaker names, forwarded to
    ///   ``Meeting/isOwnerAttributed(_:ownerNames:)`` per segment. Threaded through
    ///   rather than looked up here, so this stays free of a `ModelContext`.
    public init(meeting: Meeting, ownerNames: Set<String>) {
        self.uuid = meeting.stableID
        self.title = meeting.title
        self.kind = meeting.kind
        self.startedAt = meeting.startedAt
        self.endedAt = meeting.endedAt
        self.participantNames = meeting.participantNames
        self.roughNotes = meeting.roughNotes
        self.enhancedNotes = meeting.enhancedNotes
        // Reconciled, not read raw: a relabel or isMe change after enhancement can
        // strand a persisted item on stale identity, and export is the boundary
        // where staleness would turn into an agent acting on it.
        self.actionItems = meeting.reconciledActionItems(ownerNames: ownerNames)
        self.segments =
            meeting.segments
            // startTime alone can't order this deterministically: the two engines run
            // independently and both start at 0, and SwiftData relationship order is
            // not stable across processes. Tie-break on everything that reaches the
            // payload, so identical meetings serialize to identical bytes.
            .sorted {
                ($0.startTime, $0.endTime, $0.channelRaw, $0.displayLabel, $0.text)
                    < ($1.startTime, $1.endTime, $1.channelRaw, $1.displayLabel, $1.text)
            }
            .map { segment in
                Segment(
                    displayLabel: segment.displayLabel,
                    channel: segment.channel,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    text: segment.text,
                    isOwner: Meeting.isOwnerAttributed(segment, ownerNames: ownerNames)
                )
            }
    }

    /// The `JSONEncoder` every consumer must use — ISO 8601 dates explicitly, not
    /// whatever `Codable`'s `.deferredToDate` default would emit (seconds since 2001,
    /// meaningless outside this process). Output is deterministic (sorted keys, no
    /// escaped slashes) so two consumers serializing the same meeting produce the same
    /// bytes — and so the fixture test pins exactly what consumers ship.
    public static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension Meeting {
    /// See ``MeetingExport/init(meeting:ownerNames:)``.
    public func export(ownerNames: Set<String>) -> MeetingExport {
        MeetingExport(meeting: self, ownerNames: ownerNames)
    }
}
