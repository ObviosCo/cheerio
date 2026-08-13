import Foundation
import SwiftData

/// The decisions around re-transcribing a meeting already in the library (issue
/// #14): whether a channel can be re-run, whether it looks like it *should* be, and
/// what happens to the lines already there when a fresh pass comes back.
///
/// Per channel, never per meeting. The case this exists for is one channel empty and
/// the other fine — issue #174's mic bug left a 58-minute call with the far end
/// transcribed and the owner's own side blank — and re-running both would spend the
/// same minutes to throw away text that was never wrong.
///
/// Nothing here reads a microphone or a model, so it lives in `CheerioKit` beside
/// the rest of the transcript logic; the app target owns only the sequencing (a
/// processing mark, the diarization pass after) and the button.
public enum TranscriptRepair {

    // MARK: - Whether a channel can be re-transcribed

    /// Why a channel can't be re-transcribed right now.
    public enum Refusal: LocalizedError, Equatable {
        /// No CAF for this channel: retention purged the meeting's audio, or the
        /// channel never wrote a file at all. Indistinguishable from here, and
        /// deliberately so — both mean the same thing to a person looking for their
        /// missing half of a conversation.
        case audioUnavailable
        /// Something already has this meeting mid-mutation, or a recording is
        /// running. See ``audioFile(for:in:isBusy:resolve:)`` for why the caller
        /// supplies that fact rather than this deciding it.
        case busy
        /// The pass came back with no text at all for a channel that already had
        /// some. See ``replace(channel:in:with:context:)``.
        case nothingTranscribed

        public var errorDescription: String? {
            switch self {
            case .audioUnavailable:
                "This meeting's audio has been deleted, so it can't be transcribed again. Check the retention setting in Settings → Privacy."
            case .busy:
                "Cheerio is already working on this meeting. Try again once it's finished."
            case .nothingTranscribed:
                "Transcribing that channel again produced no text at all, so the lines it already had were left alone. Audio that transcribed once shouldn't come back empty, so this is more likely a failed pass than a silent recording."
            }
        }
    }

    /// The file a re-transcription of `channel` would read, or a ``Refusal``.
    ///
    /// `isBusy` is passed in rather than looked up: what counts as busy is the app
    /// target's `CaptureSession` — its reference-counted processing marks (issue
    /// #156) plus whether a recording is in progress at all — and none of that is
    /// portable or visible from here. Same division as `TranscriptionCoverage`: the
    /// caller collects the facts, this owns the verdict.
    ///
    /// Two transcription engines are already running during a recording, and a
    /// third reading a file as fast as the disk allows would compete with the live
    /// meeting for exactly the resources it can least afford to lose. That's why a
    /// recording anywhere — not just on this meeting — is a refusal, unlike the
    /// re-identify pass, which reads audio without an analyzer.
    public static func audioFile(
        for channel: SpeakerChannel,
        in meeting: Meeting,
        isBusy: Bool,
        resolve: (String) throws -> URL = AudioStorage.url(forRelativePath:)
    ) throws -> URL {
        guard !isBusy else { throw Refusal.busy }
        guard
            let match = MeetingAudioPlayback.channelFiles(for: meeting, resolve: resolve)
                .first(where: { $0.channel == channel })
        else { throw Refusal.audioUnavailable }
        return match.url
    }

    // MARK: - Whether it looks like it should be

    /// One channel of a finished meeting, as the facts a repair prompt is decided
    /// from: where its audio is, and how much transcript it produced.
    ///
    /// A value type on purpose — a `Meeting` is a SwiftData model and can't cross
    /// to another actor, while measuring an hour of audio is exactly what shouldn't
    /// run where the UI lives. Building these is a cheap, main-actor read; acting
    /// on them isn't.
    public struct ChannelProbe: Sendable, Equatable {
        public let channel: SpeakerChannel
        public let audioFile: URL
        /// Segments this channel contributed, bleed marks included: a line marked
        /// as the far end heard through the speakers is still evidence the channel
        /// transcribed *something*, so it isn't a channel that produced nothing.
        public let segmentCount: Int

        public init(channel: SpeakerChannel, audioFile: URL, segmentCount: Int) {
            self.channel = channel
            self.audioFile = audioFile
            self.segmentCount = segmentCount
        }
    }

    /// Every channel of `meeting` whose audio is still on disk. Empty once
    /// retention has purged it, which is what hides the whole affordance — the same
    /// rule playback and "use as a voice sample" already follow.
    public static func probes(
        in meeting: Meeting,
        resolve: (String) throws -> URL = AudioStorage.url(forRelativePath:)
    ) -> [ChannelProbe] {
        MeetingAudioPlayback.channelFiles(for: meeting, resolve: resolve).map { channel, url in
            ChannelProbe(
                channel: channel,
                audioFile: url,
                segmentCount: meeting.segments.count { $0.channel == channel }
            )
        }
    }

    /// How much of a silent-looking channel is scanned before the prompt gives up
    /// on finding speech in it. Five minutes is long enough to cover a call that
    /// starts with a minute of "can you hear me", short enough that clicking through
    /// a library of in-person meetings — every one of which has a silent system
    /// channel — doesn't read gigabytes of zeroes.
    ///
    /// Measured, on the recording this feature exists for: a full scan of issue
    /// #174's 58-minute, 3 ch / 24 kHz mic channel (1.0 GB) takes ~21 s in a debug
    /// build, and that is per channel, per meeting opened. That number is the reason
    /// this bound exists at all.
    public static let promptScanBudget: TimeInterval = 300

    /// The coverage verdict for one channel, asked after the fact.
    ///
    /// `TranscriptionCoverage` (issue #176) pairs "did this channel hear anything"
    /// with "did it produce text", and `CaptureSession` asks it once, at the end of
    /// a recording, while the capture sources still hold the answer. This asks the
    /// same question of a meeting already in the library, where the only remaining
    /// witness is the CAF — and that verdict is precisely the signal that a channel
    /// wants re-transcribing, rather than leaving someone to guess which half of
    /// their meeting is missing.
    ///
    /// Nil when the pairing can't be the bug, *without reading a byte*: a channel
    /// that produced segments is consistent whatever its audio measures, so opening
    /// a healthy meeting never touches the audio path.
    ///
    /// Only a channel with no segments at all is measured, and the measurement is
    /// deliberately bounded — the first ``promptScanBudget`` seconds, stopping the
    /// moment it finds signal. Both bounds exist because this question is asked
    /// every time a meeting is opened: the yes case (issue #174's recording is loud
    /// from its first seconds) costs one window, and the no case — an in-person
    /// meeting's silent `them.caf`, which is the common one — costs a few megabytes
    /// instead of the whole hour. The cost of bounding it is a channel that stays
    /// silent for five minutes and then talks, with no transcript, going
    /// un-prompted; the affordance itself is still there, since it never depended on
    /// this verdict.
    ///
    /// The silence test is the mic's level floor for both channels, not the tap's
    /// any-nonzero test: reading a finished file, "did it ever get louder than
    /// −60 dBFS" is answerable for real, so there's no reason to keep the weaker
    /// live-only test that existed because the tap has no meter.
    ///
    /// Deliberately *not* public, unlike everything else here: it reads audio
    /// synchronously, so the only way in from outside this file is
    /// ``channelsWantingRepair(_:)``, which is `@concurrent` and therefore can't run
    /// on a caller's actor. An internal-only synchronous door can't be opened from a
    /// view by accident.
    static func coverage(for probe: ChannelProbe) throws -> TranscriptionCoverage? {
        guard probe.segmentCount == 0 else { return nil }
        let signal = try AudioFileSignal.measuring(
            probe.audioFile, scanning: promptScanBudget, stoppingAtFirstSignal: true)
        return TranscriptionCoverage(
            channel: probe.channel,
            carriedSignal: CapturePeakWatch.Verdict(peak: signal.peak).isSignal,
            peak: signal.peak,
            format: signal.format,
            segmentCount: probe.segmentCount
        )
    }

    /// Every channel that captured audio and produced no transcript from it — the
    /// ones worth prompting about.
    ///
    /// `@concurrent`, and that attribute is load-bearing rather than decoration:
    /// ``coverage(for:)`` reads and decodes audio *synchronously*, so this function
    /// body has no suspension point of its own, and a plain `nonisolated async`
    /// function is free to run on its caller's executor — under Swift 6.2's
    /// caller-inheriting default it does exactly that. Called from a view, that
    /// would scan a meeting's audio on the main thread and stall rendering. This
    /// attribute is what actually leaves the main actor; the `Sendable` value types
    /// in and out are what let it.
    ///
    /// A channel whose measurement throws is dropped: a prompt is a courtesy, and a
    /// file that can't be read is a problem the repair itself will report properly.
    @concurrent
    public static func channelsWantingRepair(_ probes: [ChannelProbe]) async -> [TranscriptionCoverage] {
        probes
            .compactMap { try? coverage(for: $0) }
            .filter { $0.verdict == .signalWithoutTranscript }
    }

    // MARK: - Merging a fresh pass into an existing transcript

    /// What a repair did, for the line the UI shows afterward.
    public struct Outcome: Sendable, Equatable {
        /// Fresh lines written to the meeting.
        public let inserted: Int
        /// Machine-labelled lines the fresh pass replaced.
        public let replaced: Int
        /// Human-settled lines left exactly as they were.
        public let kept: Int
        /// Fresh lines dropped because they overlap a kept line — see
        /// ``replace(channel:in:with:context:)``.
        public let skipped: Int

        public init(inserted: Int, replaced: Int, kept: Int, skipped: Int) {
            self.inserted = inserted
            self.replaced = replaced
            self.kept = kept
            self.skipped = skipped
        }
    }

    /// A stretch of a channel's timeline that a human has already spoken for.
    public struct Span: Sendable, Equatable {
        public let start: TimeInterval
        public let end: TimeInterval

        public init(start: TimeInterval, end: TimeInterval) {
            self.start = start
            self.end = end
        }

        /// Half-open on both sides, so lines that merely touch at an endpoint —
        /// one ending exactly where the next begins, the common case between
        /// consecutive segments — don't count as overlapping.
        func overlaps(start otherStart: TimeInterval, end otherEnd: TimeInterval) -> Bool {
            otherStart < end && start < otherEnd
        }
    }

    /// Replaces `channel`'s transcript with `lines`, keeping every line a human
    /// settled.
    ///
    /// **The rule, and it is the one the rest of the app already follows:** a
    /// segment carrying `isSpeakerLabelManual` or `isSpeakerLabelConfirmed` is
    /// testimony, and testimony outranks a machine pass — the same precedence
    /// diarization gives it (`SpeakerLabeling.label`) and the bleed detector gives
    /// it (issue #170). So a settled line survives a re-pass untouched, and every
    /// unsettled line on that channel is replaced.
    ///
    /// Refusing to touch a settled *channel* was the alternative, and it's the
    /// worse trade: one confirmed label out of forty would make the whole channel
    /// unrepairable, and the only way back would be un-confirming lines one at a
    /// time to earn the right to fix the rest.
    ///
    /// What preserving costs is the risk of saying the same words twice — a kept
    /// line and a fresh line covering the same seconds — so a fresh line that
    /// overlaps a kept one is dropped rather than added. For those seconds the
    /// human-settled line *is* the record; a duplicate under two labels is worse
    /// than one utterance the re-pass didn't get to improve, and the audio is still
    /// there if they'd rather clear the label and run it again.
    ///
    /// The other channel is never read or written.
    ///
    /// A pass that produced *nothing* for a channel that already had unsettled
    /// lines throws ``Refusal/nothingTranscribed`` instead of emptying it. Those
    /// lines came out of this same audio once, so a second pass finding no speech
    /// in it says something went wrong with the pass — a converter that gave up, a
    /// locale with no model — and deleting a transcript on that evidence would turn
    /// a recovery feature into a way to lose the half that worked. A channel that
    /// had nothing to begin with is allowed to come back with nothing: that's the
    /// honest answer for a recording with no speech in it, and the outcome says so.
    @discardableResult
    public static func replace(
        channel: SpeakerChannel,
        in meeting: Meeting,
        with lines: [TranscriptionUpdate],
        context: ModelContext
    ) throws -> Outcome {
        let existing = meeting.segments.filter { $0.channel == channel }
        let kept = existing.filter { $0.isSpeakerLabelManual || $0.isSpeakerLabelConfirmed }
        let stale = existing.filter { !($0.isSpeakerLabelManual || $0.isSpeakerLabelConfirmed) }
        let spans = kept.map { Span(start: $0.startTime, end: $0.endTime) }

        let candidates = usableLines(lines, for: channel)
        guard !candidates.isEmpty || stale.isEmpty else { throw Refusal.nothingTranscribed }
        let insertable = insertable(candidates, keeping: spans)

        for segment in stale {
            context.delete(segment)
        }
        for line in insertable {
            let segment = TranscriptSegment(
                channel: channel,
                text: line.text,
                startTime: line.startTime,
                endTime: line.endTime
            )
            segment.meeting = meeting
            context.insert(segment)
        }
        // Not `try?`: the whole point of the pass is that the recovered half of the
        // meeting is on disk afterward, and a caller told it succeeded when it
        // didn't would be worse than an error.
        try context.save()

        return Outcome(
            inserted: insertable.count,
            replaced: stale.count,
            kept: kept.count,
            skipped: candidates.count - insertable.count
        )
    }

    /// The lines from a pass that are worth storing: finalized, on the channel that
    /// was asked for, and carrying actual words. Volatile results and blank lines
    /// exist in a live stream and mean nothing in a transcript.
    static func usableLines(_ lines: [TranscriptionUpdate], for channel: SpeakerChannel) -> [TranscriptionUpdate] {
        lines.filter {
            $0.isFinal && $0.channel == channel
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Which fresh lines actually go in: all of them, minus any that overlap a span
    /// a human already settled. Pure arithmetic so the merge rule is pinned by
    /// tests rather than by a recording.
    static func insertable(_ lines: [TranscriptionUpdate], keeping spans: [Span]) -> [TranscriptionUpdate] {
        guard !spans.isEmpty else { return lines }
        return lines.filter { line in
            !spans.contains { $0.overlaps(start: line.startTime, end: line.endTime) }
        }
    }
}
