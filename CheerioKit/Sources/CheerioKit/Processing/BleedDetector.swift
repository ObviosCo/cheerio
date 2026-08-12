import Foundation

/// Finds speaker bleed: mic-channel transcript lines that are really the far end of a
/// call, heard through the speakers, transcribed a second time (issue #5).
///
/// The far end is already cleanly on the system-tap channel, so the mic's copy carries
/// no information — it only duplicates the transcript and mis-attributes the words to
/// "Me". The copy is detected where the evidence actually is, in the transcript:
/// a Me line whose text is a fuzzy near-duplicate of what the Them channel said at
/// overlapping time is bleed. Only the Me channel is ever a candidate; the direction
/// is asymmetric by construction, because the tap reads the call app's output
/// digitally and can't hear the room.
///
/// This is a text-level post-pass, not DSP: the retained audio keeps the bleed, and
/// the live transcript shows it until processing runs. Both matter for honesty —
/// re-running detection over the same segments always reaches the same verdicts,
/// and a wrong verdict is a flag flip away from being revisited, never lost audio.
///
/// Every constant errs toward keeping a line. A dropped piece of genuine cross-talk
/// is speech the summary never sees and no one can get back; a kept piece of bleed is
/// the status quo this exists to improve on. Time only *gates* candidate pairs —
/// simultaneous speech is normal in any real call — and the text similarity makes the
/// call; the timing gate itself is directional, requiring a candidate to start while
/// its source is still being spoken, because a person repeating the far end's words
/// back waits for the phrase to end and bleed, by its physics, never does.
public enum BleedDetector {
    /// One transcript line, as much of it as matching needs. A value type rather
    /// than `TranscriptSegment` so the matching stays pure and the tests need no
    /// model container.
    public struct Line: Sendable, Equatable {
        public let text: String
        /// Seconds from meeting start, matching ``TranscriptSegment/startTime``.
        public let startTime: TimeInterval
        public let endTime: TimeInterval

        public init(text: String, startTime: TimeInterval, endTime: TimeInterval) {
            self.text = text
            self.startTime = startTime
            self.endTime = endTime
        }
    }

    /// How far apart in time a Me line and a Them line can sit and still be the same
    /// utterance. The two channels run independent transcription engines, and the
    /// mic's copy arrives through air and a second recognition pass, so its
    /// timestamps land 0.5–2s off the tap's for the same words. Measured skew tops
    /// out around 2s; the extra half second is slack, and is safe to grant because
    /// this gate only nominates candidates — text similarity still has to convict.
    public static let timingSkewTolerance: TimeInterval = 2.5

    /// Minimum similarity (see ``similarity(of:toReferenceOf:)``) for a Me line to
    /// be called bleed. Bleed transcribes imperfectly — muffled words come back as
    /// near-homophones — so exact matching would miss most of it. Measured against
    /// the fixtures: real bleed scores 0.93+ even with several misheard words,
    /// unrelated simultaneous speech stays under 0.4, and the hardest genuine case
    /// — quoting the far end's words back — reaches 0.63. 0.75 sits with margin on
    /// both sides, more of it on the side that matters: a missed bleed line is the
    /// pre-detector status quo, a false drop is speech nothing can recover.
    public static let similarityThreshold: Double = 0.75

    /// A Me line shorter than this many normalized words is never marked, no matter
    /// how well it matches. Short near-identical lines at overlapping time are
    /// exactly what genuine conversation produces — "yeah", "okay okay", both sides
    /// echoing "thanks, bye" at a sign-off — and text alone can't tell those from
    /// bleed. Real bleed is continuous far-end speech and transcribes as full
    /// sentences, so the length gate costs little of it, and what it does keep is
    /// the status quo, not a regression.
    public static let minimumWordCount = 5

    /// How much earlier than its source a Me line may start and still count as
    /// starting inside that source's span (see ``startsInsideSpan(of:candidate:)``).
    /// The acoustic path and second recognition pass only ever *delay* the mic's
    /// copy, so a genuine copy can't meaningfully precede its source — this is
    /// jitter allowance for two engines rounding the same onset differently, not a
    /// second skew window.
    public static let startJitterAllowance: TimeInterval = 0.5

    /// The offsets into `micLines` judged to be bleed from `systemLines`.
    ///
    /// Order doesn't matter to the verdicts — every Me line is judged against the
    /// union of Them lines near it in time — but offsets are only meaningful against
    /// the exact array passed in.
    public static func bleedOffsets(micLines: [Line], systemLines: [Line]) -> Set<Int> {
        guard !systemLines.isEmpty else { return [] }
        let system =
            systemLines
            .sorted { $0.startTime < $1.startTime }
            .map { (line: $0, words: normalizedWords($0.text)) }

        var offsets: Set<Int> = []
        for (offset, micLine) in micLines.enumerated() {
            let micWords = normalizedWords(micLine.text)
            guard micWords.count >= minimumWordCount else { continue }

            // Bleed is *simultaneous* with its source — the mic hears the speakers
            // while they play — so a real copy starts while some Them line is
            // still being spoken. A person echoing a phrase back waits for it to
            // end first, and the far end repeating *your* words starts after you
            // did: both land outside every source's span, and no amount of text
            // similarity may convict them. This is the gate that keeps a short
            // verbatim clarification ("Ship the fix on Tuesday?") alive when the
            // length gate and the similarity score both fail it.
            guard system.contains(where: { startsInsideSpan(of: $0.line, candidate: micLine) })
            else { continue }

            // The reference is everything the far end said near this line, joined
            // — wider than the span-containing sources on purpose: the engines
            // segment independently, so one Me copy can run past its source into
            // the next Them line, and the free ends of the semi-global alignment
            // absorb whatever the extra reference says.
            let reference =
                system
                .filter { gap(between: micLine, and: $0.line) <= timingSkewTolerance }
                .flatMap(\.words)
            guard !reference.isEmpty else { continue }

            if similarity(of: micWords, toReferenceOf: reference) >= similarityThreshold {
                offsets.insert(offset)
            }
        }
        return offsets
    }

    /// Whether `candidate` starts while `source` is being spoken — within
    /// ``startJitterAllowance`` of its start at the early end, strictly before its
    /// end at the late end.
    ///
    /// The one bleed this deliberately misses: a Them utterance so short that the
    /// 0.5–2s recognition skew pushes the mic copy's start past the source's end.
    /// That copy is indistinguishable *by timing* from a person echoing the phrase
    /// back — and a verbatim echo is indistinguishable by text — so the tie goes to
    /// keeping, per this file's ordering of harms: a duplicate line in the
    /// transcript is the pre-detector status quo; a vanished human reply is data
    /// loss.
    static func startsInsideSpan(of source: Line, candidate: Line) -> Bool {
        candidate.startTime >= source.startTime - startJitterAllowance
            && candidate.startTime < source.endTime
    }

    /// Seconds between two lines' time ranges — zero when they overlap.
    static func gap(between a: Line, and b: Line) -> TimeInterval {
        max(0, max(a.startTime, b.startTime) - min(a.endTime, b.endTime))
    }

    /// Lowercased words with punctuation stripped, because the two recognition
    /// passes disagree freely about casing, commas, and sentence breaks even when
    /// they heard the same thing.
    static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// How much of `candidate` is explained by some contiguous stretch of
    /// `reference`, in 0...1.
    ///
    /// Semi-global edit distance over the words re-joined as characters: the
    /// reference's ends are free (the Me line is usually a window into a longer
    /// Them stretch), but every unmatched candidate character costs. Character
    /// level rather than word level because bleed's errors are near-homophones —
    /// "ship the fix" heard as "shift the six" — which word-identity matching
    /// scores as three misses and character distance correctly scores as nearly
    /// right. Extra words *in the candidate* still cost full insertions, which is
    /// what keeps "so you're saying ship it Tuesday?" — a person quoting the far
    /// end back — below the threshold even though its tail matches perfectly.
    static func similarity(of candidate: [String], toReferenceOf reference: [String]) -> Double {
        let pattern = Array(candidate.joined(separator: " "))
        let text = Array(reference.joined(separator: " "))
        guard !pattern.isEmpty else { return 0 }
        guard !text.isEmpty else { return 0 }

        // dp[j] = min edits aligning pattern[0..<i] to a reference substring ending
        // at j. Row 0 is all zeros: starting anywhere in the reference is free.
        var previous = [Int](repeating: 0, count: text.count + 1)
        var current = [Int](repeating: 0, count: text.count + 1)
        for i in 1...pattern.count {
            current[0] = i
            for j in 1...text.count {
                let substitution = previous[j - 1] + (pattern[i - 1] == text[j - 1] ? 0 : 1)
                current[j] = min(substitution, previous[j] + 1, current[j - 1] + 1)
            }
            swap(&previous, &current)
        }
        // Ending anywhere in the reference is free too: take the best endpoint.
        let distance = previous.min() ?? pattern.count
        return 1 - Double(distance) / Double(pattern.count)
    }
}

extension Meeting {
    /// Runs ``BleedDetector`` over this meeting's finished transcript and sets
    /// ``TranscriptSegment/isBleed`` accordingly on every mic-channel line. Returns
    /// how many segments changed, so a caller with nothing new can skip a save.
    ///
    /// Marks rather than deletes: every consumer that should not see bleed —
    /// ``transcriptText``, ``speakerSummaries``, the export — excludes flagged
    /// segments itself, and the row stays in the store so a wrong verdict (or a
    /// better detector later) can be undone without having destroyed anything.
    ///
    /// Assigns the verdict both ways — marking and unmarking — because the inputs
    /// (text and timestamps) never change after recording, so re-running is
    /// idempotent and a re-run under improved constants heals old verdicts instead
    /// of only ever accumulating them. Human-settled lines are the one exception:
    /// a person who renamed or confirmed a line has said it's real speech, and that
    /// testimony outranks the detector the same way it outranks the diarizer.
    @discardableResult
    public func markBleedSegments() -> Int {
        let micSegments =
            segments
            .filter { $0.channel == .me }
            .sorted { $0.startTime < $1.startTime }
        let systemLines =
            segments
            .filter { $0.channel == .them }
            .map { BleedDetector.Line(text: $0.text, startTime: $0.startTime, endTime: $0.endTime) }

        let bleedOffsets = BleedDetector.bleedOffsets(
            micLines: micSegments.map {
                BleedDetector.Line(text: $0.text, startTime: $0.startTime, endTime: $0.endTime)
            },
            systemLines: systemLines
        )

        var changed = 0
        for (offset, segment) in micSegments.enumerated() {
            guard !segment.isSpeakerLabelManual, !segment.isSpeakerLabelConfirmed else { continue }
            let verdict = bleedOffsets.contains(offset)
            if segment.isBleed != verdict {
                segment.isBleed = verdict
                changed += 1
            }
        }
        return changed
    }
}
