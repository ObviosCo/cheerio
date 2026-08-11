import Foundation
import SwiftData

/// Which capture channel a transcript segment came from.
public enum SpeakerChannel: String, Codable, Sendable {
    /// Microphone — the user.
    case me
    /// System audio — everyone else on the call.
    case them
}

/// What a recording is, so downstream agents can route on the difference.
///
/// A directive session (talking instructions at your agent, alone) isn't a meeting.
/// Capture can start as either kind — the menu bar's "Give Direction…" and the main
/// window's matching control (issue #107) both set it at record time — and
/// ``Meeting/toggleKind()`` lets a person fix a mislabeled recording afterward.
public enum MeetingKind: String, Codable, Sendable {
    case meeting
    case directive
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
    /// The action items behind ``enhancedNotes``, already vetted by
    /// ``ActionItem/resolved(from:ownerNames:)``.
    ///
    /// Persisted alongside the Markdown rather than parsed back out of it: prose is a
    /// lossy carrier for `isOwner` and `disposition`, and regenerating them means
    /// re-running the model over audio that retention may have purged. Defaulted so
    /// existing stores migrate additively.
    public var actionItems: [ActionItem] = []
    /// Path to the recorded audio files, relative to Application Support. Nil once purged.
    public var audioDirectory: String?
    /// Which enrolled voices were in this meeting, by name.
    ///
    /// Nil means nobody has said, which is not the same as `[]` — an empty roster is
    /// the right answer for an all-remote call, where priming anyone is pointless
    /// because the mic/system split already separates you from them.
    public var participantNames: [String]?
    /// Backing storage for ``speakerSlotAssigner``. Optional on purpose, and the
    /// distinction is load-bearing: SwiftData flattens a composite struct into
    /// mandatory sub-attributes, and a Swift-side default value never becomes a
    /// store-level default — so a non-optional composite makes lightweight
    /// migration of every pre-existing store fail with "missing attribute values
    /// on mandatory destination attribute", which crashed 26.8.10 at launch on
    /// any Mac that had used an earlier version. An optional migrates as NULL.
    /// (A primitive with a default, like ``kindRaw``, is fine — the trap is
    /// composites only.)
    private var speakerSlotAssignerStorage: SpeakerSlotAssigner?
    /// Speaker-to-colour slot assignments, stable across relaunches — the slot is
    /// part of a speaker's identity, not a view detail, so it lives on the meeting
    /// rather than on whatever view model happens to be rendering it today.
    /// See ``SpeakerSlotAssigner``; non-optional facade over the optional storage
    /// above, so call sites never see the migration concern.
    public var speakerSlotAssigner: SpeakerSlotAssigner {
        get { speakerSlotAssignerStorage ?? SpeakerSlotAssigner() }
        set { speakerSlotAssignerStorage = newValue }
    }
    /// Raw storage for ``kind``, following the same pattern as
    /// ``TranscriptSegment/channelRaw`` — a string survives an unrecognized future case
    /// better than an enum would. Defaulted so existing stores migrate additively.
    public var kindRaw: String = MeetingKind.meeting.rawValue
    /// Process-independent identifier. Nil for meetings written before this field
    /// existed — see ``stableID``, which backfills it lazily rather than this property
    /// defaulting non-optionally, which would risk every migrated row landing on the
    /// same value.
    public var uuid: UUID?
    /// Set for exactly as long as this meeting sits in the post-meeting holding
    /// state (issue #136) — recording stopped and persisted, processing not yet
    /// claimed — and nil at every other moment of its life. Non-nil is the
    /// persisted marker that processing is still owed, which is what makes the
    /// holding state safe to quit or crash out of: the next launch finds the plan
    /// and processes the meeting with it (``awaitingProcessing(in:)``), so no
    /// meeting is ever stranded un-summarized because a window closed.
    ///
    /// An *optional* composite, and the optionality is load-bearing twice over:
    /// nil-vs-set carries the "processing owed" state itself, and — see
    /// ``speakerSlotAssignerStorage``'s doc for the 26.8.10 incident — a
    /// non-optional composite would fail lightweight migration for every
    /// pre-existing store, while an optional migrates every old row as NULL,
    /// which here is also the correct answer ("nothing pending").
    public var pendingProcessingPlan: ProcessingPlan?
    /// Whether ``endedAt`` was backfilled by
    /// `StorageMigration.closeAbandonedRecordings` — a crash or force-quit
    /// mid-recording — rather than set by an actual stop. The distinction exists
    /// because `endedAt != nil` alone can't say whether the processing pipeline
    /// ever had its chance: an abandoned row never ran diarization or
    /// enhancement, while every cleanly-stopped meeting did (or crashed
    /// mid-pipeline, which the rest of the app deliberately treats as
    /// processed-transcript-only — see `CaptureSession.completeHold`'s claim
    /// discipline). See ``endedCleanly``, the read side.
    ///
    /// A primitive with a default, not a composite, so existing stores migrate
    /// additively (the ``kindRaw`` pattern; contrast
    /// ``speakerSlotAssignerStorage``'s trap). Old rows — including ones an
    /// earlier build closed as abandoned — read `false`; that bias is chosen:
    /// hiding the callback affordance on a legacy library's genuinely processed
    /// meetings would be the worse failure, and a legacy abandoned row wrongly
    /// offering it is both rare and harmless (the export carries whatever
    /// exists).
    public var wasAbandoned: Bool = false
    /// Whether this recording reached an actual stop — ended, and not by
    /// ``wasAbandoned``'s backfill. This is the honest stand-in for "processing
    /// completed, successfully or conclusively not": the pipeline runs
    /// synchronously off every clean stop (and launch recovery covers a quit
    /// mid-hold), so a cleanly-ended meeting has had its processing chance by
    /// definition, while an abandoned one never did. Surfaces that hand the
    /// meeting to external tooling as "ready" gate on this rather than on
    /// `enhancedNotes != nil`, which is also nil when enhancement conclusively
    /// failed — a state the callback contract explicitly ships as-is.
    public var endedCleanly: Bool {
        endedAt != nil && !wasAbandoned
    }

    /// Whether `title` is a placeholder Cheerio generated (the "Meeting <date,
    /// time>" / "Direction — <date, time>" pattern) rather than one a calendar event
    /// or a person supplied.
    ///
    /// The title parallel to ``TranscriptSegment/isSpeakerLabelManual``: a
    /// machine-made value stays open to being replaced by a better machine guess
    /// (``applyGeneratedTitle(_:)``), while a human decision — a calendar event's
    /// name, or ``rename(to:)`` — closes that door for good. See ``shouldAutoTitle``
    /// for the actual gate auto-titling checks.
    ///
    /// Defaulted `false` so existing rows migrate additively onto "someone decided
    /// this title," the safe assumption for a title nobody tagged before this
    /// property existed. `Meeting.init` can't set this correctly itself — it has no
    /// way to tell a timestamp placeholder from a name someone typed — so whichever
    /// call site constructs a meeting with a generated placeholder must set it
    /// `true` explicitly. Today that's ``CaptureSession``, which does so based on
    /// whether a calendar event supplied the title.
    public var isTitleAutomatic: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \TranscriptSegment.meeting)
    public var segments: [TranscriptSegment] = []

    public init(title: String, startedAt: Date = .now, calendarEventID: String? = nil) {
        self.title = title
        self.startedAt = startedAt
        self.calendarEventID = calendarEventID
        self.roughNotes = ""
    }

    public var kind: MeetingKind {
        get { MeetingKind(rawValue: kindRaw) ?? .meeting }
        set { kindRaw = newValue.rawValue }
    }

    /// Whether this meeting is eligible for auto-titling: the title is still the
    /// machine-made placeholder, and no calendar event supplied it instead.
    ///
    /// The `calendarEventID` check is belt-and-suspenders alongside
    /// ``isTitleAutomatic`` — a correctly-maintained flag already implies this, but
    /// checking both means a bug that leaves the flag `true` on a calendar-derived
    /// title still can't cost the user that title.
    public var shouldAutoTitle: Bool {
        isTitleAutomatic && calendarEventID == nil
    }

    /// A person naming this meeting — the rename affordance in the library list and
    /// the detail view. Always wins: like
    /// ``TranscriptSegment/assignSpeaker(_:)`` retiring the diarizer's claim on a
    /// line once a human names it, this retires ``isTitleAutomatic`` for good, so no
    /// later auto-title pass can overwrite it.
    ///
    /// A blank rename is a non-event, not a rename: the live bindings call this on
    /// every keystroke, so clearing the field mid-edit (or abandoning it empty) must
    /// neither blank the title permanently nor burn auto-title eligibility.
    public func rename(to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        title = trimmed
        isTitleAutomatic = false
    }

    /// Applies a model-generated title in place of the placeholder — issue #32's
    /// auto-title. Leaves ``isTitleAutomatic`` set, unlike ``rename(to:)``: this is
    /// still just the machine's best guess, so a later, better transcript could in
    /// principle retitle the meeting again. Only a person typing a name closes that
    /// door.
    public func applyGeneratedTitle(_ newTitle: String) {
        title = newTitle
    }

    /// Flips ``kind`` between ``MeetingKind/meeting`` and ``MeetingKind/directive`` —
    /// the "Convert to Directive"/"Convert to Meeting" action (issue #107), for a
    /// recording started as the wrong kind. Both kinds have the same start-time
    /// controls now (menu bar and main window), but a person can still misjudge which
    /// button they meant, or realize only partway through that a call was really them
    /// dictating to their agent.
    ///
    /// Mechanical only: this changes ``kind`` (and, downstream, the badge, the
    /// directives-only filter, and every exported `kind` field, since all three read
    /// this same stored value) and nothing else. It deliberately does not re-run
    /// ``enhancedNotes``. As of this writing ``SummarizationEngine`` doesn't yet branch
    /// its prompt on kind at all, so nothing here is stale *today* — but the
    /// conservative choice is made ahead of that seam existing anyway: a silent
    /// re-enhancement on convert would spend a model pass nobody asked for and replace
    /// notes the person may still want, and once the prompt does differ by kind, doing
    /// it silently would turn a meeting's notes into directive-shaped ones (or back)
    /// without anyone deciding that's wanted. Re-enhancement-on-convert is a deliberate
    /// follow-up, not an oversight.
    public func toggleKind() {
        kind = kind == .meeting ? .directive : .meeting
    }

    /// A stable identifier for this meeting, usable across processes — unlike
    /// SwiftData's `persistentModelID`, which is only valid within the process that
    /// minted it and can't be handed to the transcript-ready callback or MCP server.
    ///
    /// Backfills on first access: assigning `UUID()` here, rather than giving `uuid` a
    /// non-optional default, is what keeps every meeting already in the store from
    /// migrating onto the *same* generated value. Call this (or rely on any caller
    /// that does, like ``MeetingExport``) instead of reading `uuid` directly whenever
    /// the identifier needs to exist.
    public var stableID: UUID {
        if let uuid { return uuid }
        let id = UUID()
        uuid = id
        return id
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
    /// Set when a person *typed* this line's label — a rename, or the "Reset to
    /// Me/Them" that hands it back to the diarizer. Distinct from
    /// ``isSpeakerLabelConfirmed`` (which vouches for a label without changing it) so
    /// the two can carry different consequences: only a manual line's transcript menu
    /// offers "Undo my change," a destructive revert to the capture channel that
    /// would wrongly discard a model label the person merely confirmed as already
    /// correct, never actually retyped. Re-identifying speakers leaves both alone —
    /// a human's word outranks the model either way, and losing it to a later re-run
    /// would make correcting or confirming anything pointless. A primitive with a
    /// default, so existing stores migrate additively — see
    /// ``Meeting/speakerSlotAssignerStorage``'s doc for the composite trap this
    /// avoids (the 26.8.10 incident).
    public var isSpeakerLabelManual: Bool = false
    /// Set when a person vouched for this line's *model-matched* label without
    /// retyping it — ``Meeting/confirmSpeaker(_:)``. Never set alongside a
    /// diarizer-generated or channel-default label: there's no model guess there to
    /// confirm. Kept separate from ``isSpeakerLabelManual`` rather than folded into
    /// it (see that property's doc) and cleared by ``assignSpeaker(_:)`` the moment a
    /// line is renamed or reset, so the two states never linger stale together.
    public var isSpeakerLabelConfirmed: Bool = false
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
    ///
    /// Clears ``isSpeakerLabelConfirmed`` unconditionally: a rename replaces whatever
    /// was confirmed with a fresh, already-manual label, and a reset to nil removes
    /// the model guess there was ever anything to confirm. Either way, leaving the
    /// bit set would let it outlive the label it was about.
    public func assignSpeaker(_ label: String?) {
        speakerLabel = label
        isSpeakerLabelManual = label != nil
        isSpeakerLabelConfirmed = false
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

    /// The identity key this segment's colour slot is filed under — matches
    /// ``SpeakerSummary/id`` for the speaker this segment belongs to, so a rail
    /// label built straight from one segment resolves to the same
    /// ``SpeakerSlot`` as the "Who was here" row does for the whole speaker.
    /// See ``Meeting/resolveSpeakerSlots(ownerNames:)``.
    public var speakerSlotKey: String {
        let scoped = TranscriptSegment.isDiarizerGeneratedLabel(speakerLabel) ? channel : nil
        return scoped.map { "\(displayLabel)\u{1F}\($0.rawValue)" } ?? displayLabel
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
    /// True when every line under this label was named by hand — a rename, not a
    /// confirm. See ``TranscriptSegment/isSpeakerLabelManual``.
    public let isManual: Bool
    /// True when every line under this label is settled by a human either way —
    /// renamed or confirmed. Not "every line was confirmed": a speaker with one
    /// renamed line and one confirmed one is `isSettled` but not `isManual`, and
    /// the panel picks its wording off which of the two this is. See
    /// ``TranscriptSegment/isSpeakerLabelConfirmed``.
    public let isSettled: Bool

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
            let scoped =
                TranscriptSegment.isDiarizerGeneratedLabel(segment.speakerLabel)
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
                isManual: group.allSatisfy(\.isSpeakerLabelManual),
                isSettled: group.allSatisfy { $0.isSpeakerLabelManual || $0.isSpeakerLabelConfirmed }
            )
        }
        .sorted { $0.duration > $1.duration }
    }

    /// Assigns a colour slot to every speaker in ``speakerSummaries`` who doesn't
    /// already have one, in that order (most talkative first, so the common cases
    /// land on the best-separated pairs), and pins the local channel to `.you`.
    ///
    /// A speaker who already has a slot keeps it — ``SpeakerSlotAssigner/slot(for:isYou:)``
    /// only ever adds, never reassigns, so calling this again after a fresh
    /// diarization pass can't reshuffle a colour out from under someone mid-read.
    ///
    /// Prunes dead keys *before* allocating, not after — see
    /// ``SpeakerSlotAssigner/reconcile(liveIDs:)``, called against a snapshot of
    /// this same ``speakerSummaries`` list. Reconciling afterward would still see
    /// every live id already accounted for in the loop below, so there'd be
    /// nothing left for it to catch; pruning first is what lets a dead key's
    /// number reach whoever just inherited that identity — a merge, or a
    /// corrected line that happened to be the only one under its old label — in
    /// this same pass, rather than leaving them `.unresolved` for one more
    /// resolve cycle while a freed number sits idle. Renaming or merging a
    /// *whole* speaker (``relabelSpeaker(_:to:)``) rekeys instead of abandoning,
    /// so it's really only the single-corrected-line path that ever depends on
    /// this pruning to recover capacity — and even then, the freed number isn't
    /// the departing speaker's own colour, just a number back in circulation.
    ///
    /// `ownerNames` is whichever enrolled names have `isMe == true`, the same set
    /// ``isOwnerAttributed(_:ownerNames:)`` uses — a summary counts as "you" when
    /// its label names the owner directly (an enrolled "me" voice, diarized on
    /// either channel), or when it's the bare, pre-diarization "Me" fallback.
    ///
    /// Deliberately *not* every summary scoped to the mic channel: once diarization
    /// has split the mic channel into more than one voice (bleed-in from the far
    /// end, issue #5's failure mode), a `Speaker N` there isn't necessarily you —
    /// only a name match or the untouched channel default is unambiguous enough to
    /// pin outside rotation.
    @discardableResult
    public func resolveSpeakerSlots(ownerNames: Set<String>) -> [String: SpeakerSlot] {
        let summaries = speakerSummaries
        speakerSlotAssigner.reconcile(liveIDs: Set(summaries.map(\.id)))
        for summary in summaries {
            let isYou = summary.label == "Me" || ownerNames.contains(summary.label)
            speakerSlotAssigner.slot(for: summary.id, isYou: isYou)
        }
        return speakerSlotAssigner.assignments
    }

    /// Renames every line this speaker is on. Passing nil for `newLabel` reverts them
    /// to the capture channel. Returns how many lines changed.
    ///
    /// This is the fix for the diarizer splitting one person across two slots: the
    /// phantom's lines get merged into the real speaker in one move. Takes a summary
    /// rather than a bare label so a channel-scoped "Speaker 1" only renames its own
    /// channel's lines.
    ///
    /// Also rekeys ``speakerSlotAssigner`` from `speaker.id` to whatever identity
    /// the renamed lines resolve to, so this speaker's colour survives the rename
    /// (or, merging into an existing target, defers to that target's colour and
    /// frees this one's slot) instead of reading as a brand-new speaker. Skipped
    /// only in the rare case a `nil` reset splits one unscoped identity across both
    /// channels at once — genuinely ambiguous which of the resulting identities
    /// should inherit the old colour, so neither does; both pick up a fresh slot
    /// on the next ``resolveSpeakerSlots(ownerNames:)``.
    @discardableResult
    public func relabelSpeaker(_ speaker: SpeakerSummary, to newLabel: String?) -> Int {
        var changed = 0
        var newKeys: Set<String> = []
        for segment in segments where speaker.matches(segment) {
            segment.assignSpeaker(newLabel)
            newKeys.insert(segment.speakerSlotKey)
            changed += 1
        }
        if let newKey = newKeys.first, newKeys.count == 1 {
            speakerSlotAssigner.rename(from: speaker.id, to: newKey)
        }
        return changed
    }

    /// Settles this speaker's current label without changing what it says — the "I
    /// checked, it's right" complement to ``relabelSpeaker(_:to:)``, which is "I
    /// checked, it's wrong, call them this instead."
    ///
    /// Flips every eligible line under this identity to
    /// ``TranscriptSegment/isSpeakerLabelConfirmed`` — deliberately *not*
    /// ``TranscriptSegment/isSpeakerLabelManual``, which a hand rename owns alone.
    /// The two used to share one bit, and that overloading broke the transcript's
    /// per-line "Undo my change": it's gated on `isSpeakerLabelManual`, so a
    /// confirmed line offered it too, and choosing it discarded a label that was
    /// never wrong in the first place, only unconfirmed. `SpeakerLabeling.label`'s
    /// re-identification guard, in the app target, now reads *either* bit — a
    /// confirmed line skips a re-run exactly the way a renamed one already did,
    /// since a human vouched for it either way. Because the label itself never
    /// moves, this needs none of `relabelSpeaker`'s slot-rekeying or action-item
    /// reconciliation — ``TranscriptSegment/speakerSlotKey`` and
    /// ``Meeting/isOwnerAttributed(_:ownerNames:)`` both key off the label and
    /// diarizer-generated-ness, neither of which this touches.
    ///
    /// Only settles lines that could actually be showing the ring — a real,
    /// non-diarizer-generated label nobody has settled yet. A channel-default line
    /// (no ``TranscriptSegment/speakerLabel`` at all, still reading as the bare
    /// "Me"/"Them" fallback) or a diarizer-generated one ("Speaker 2") is left alone
    /// and doesn't count toward the return value: the UI never rings either of
    /// those, but a caller that skipped that check and confirmed one anyway would
    /// set a settled bit on a line with nothing to confirm — and
    /// ``SpeakerLabeling/label`` would then skip it on every future identification
    /// pass, permanently hiding a voice nobody ever actually identified. Enforced
    /// here rather than left to the UI guard so it holds for every caller, not just
    /// this one screen. An already-manual line is left alone too, for the plainer
    /// reason that a rename already settled it.
    ///
    /// Idempotent — confirming a speaker who's already partly settled only ever
    /// sets the bit on the remaining lines, never touches one that's already
    /// manual or confirmed. There's no bulk "unconfirm" here; the transcript's
    /// per-line menu offers one for a single confirmed line (non-destructive, since
    /// the label stays), and a wrong confirm is otherwise recoverable the same way
    /// a wrong rename is, by renaming. Returns how many lines flipped, so a caller
    /// with nothing to change can skip the save.
    @discardableResult
    public func confirmSpeaker(_ speaker: SpeakerSummary) -> Int {
        var changed = 0
        for segment in segments where speaker.matches(segment) {
            guard !segment.isSpeakerLabelManual,
                !segment.isSpeakerLabelConfirmed,
                let label = segment.speakerLabel,
                !TranscriptSegment.isDiarizerGeneratedLabel(label)
            else { continue }
            segment.isSpeakerLabelConfirmed = true
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

    /// The mechanical half of the speaker-trust rule: whether a line came from the
    /// meeting's owner, for anything that needs to act only on what *you* said
    /// (owner-attributed actions, the transcript export). One function so both
    /// consumers agree instead of re-deriving it.
    ///
    /// `ownerNames` is whichever enrolled names have `isMe == true` — normally one,
    /// but the caller decides, so this stays free of any lookup of its own.
    ///
    /// A segment is the owner's when either:
    /// - its resolved label names an enrolled `isMe` speaker, on *either* channel
    ///   (diarization can put your own voice's echo on the system tap), or
    /// - it has no human-assigned identity at all — no label, or one the diarizer
    ///   invented rather than a person naming it — and it came in on the mic.
    ///
    /// A manual or enrolled label naming someone who isn't the owner is never
    /// owner-attributed, even on the mic channel: a label is a person saying "this is
    /// who spoke," and that testimony outranks which physical channel picked it up.
    /// That includes a *manually assigned* "Speaker 1" — `isSpeakerLabelManual` is
    /// checked before the label's spelling, so hand-naming a guest with a
    /// diarizer-looking name can't quietly promote their lines to owner-attributed.
    public static func isOwnerAttributed(_ segment: TranscriptSegment, ownerNames: Set<String>) -> Bool {
        if let label = segment.speakerLabel {
            if ownerNames.contains(label) { return true }
            // A human named this line: whoever they named, it isn't the owner (that
            // case returned above), no matter what the label looks like.
            guard !segment.isSpeakerLabelManual else { return false }
            guard TranscriptSegment.isDiarizerGeneratedLabel(label) else { return false }
            return segment.channel == .me
        }
        return segment.channel == .me
    }
}
