import Foundation
import Testing

@testable import CheerioKit

/// Fixture-shaped the way the two engines actually produce segments: independent
/// segmentation per channel, timestamps that disagree by 0.5–2s for the same
/// utterance, punctuation and casing that differ freely, and bleed text that came
/// through a room and a second recognition pass, so words arrive as near-homophones
/// rather than copies. These fixtures are the verification issue #5 never got — the
/// drop/keep decisions pinned here are the fix's evidence.
@Suite struct BleedDetectorTests {
    private typealias Line = BleedDetector.Line

    // MARK: - Fixture: call on headphones (clean)

    /// No speaker playback, so nothing for the mic to overhear: the channels carry
    /// different words at interleaved times, and nothing may be marked.
    private static let headphoneCallMe = [
        Line(text: "Morning! Can you hear me alright?", startTime: 0.8, endTime: 2.4),
        Line(
            text: "I got through the review backlog yesterday, two of them need your eyes.",
            startTime: 6.1, endTime: 10.3),
        Line(text: "Yeah.", startTime: 14.9, endTime: 15.2),
        Line(
            text: "Works for me, I'll move the invite and post it in the channel.",
            startTime: 24.0, endTime: 27.6),
    ]

    private static let headphoneCallThem = [
        Line(text: "Loud and clear. How'd yesterday go?", startTime: 3.0, endTime: 5.5),
        Line(
            text: "Okay, send them over after this. Can we also talk about the retro slot?",
            startTime: 11.0, endTime: 15.8),
        Line(
            text: "I'd rather move it to Thursday afternoon, Friday keeps getting eaten by travel.",
            startTime: 16.2, endTime: 21.9),
    ]

    @Test func headphoneCallDropsNothing() {
        let marked = BleedDetector.bleedOffsets(
            micLines: Self.headphoneCallMe,
            systemLines: Self.headphoneCallThem
        )
        #expect(marked.isEmpty)
    }

    // MARK: - Fixture: call played through speakers (bleed)

    /// The far end plays out loud, so every remote utterance shows up twice: clean
    /// on the tap, and again on the mic — later by 0.5–2s, segmented differently,
    /// and with the muffled-playback mishearings real bleed carries ("ship the fix"
    /// → "shift the six"). The genuine Me lines interleaved with it must survive.
    private static let speakerCallThem = [
        Line(
            text: "I think we should ship the fix on Tuesday and then watch the crash rate for a couple of days.",
            startTime: 10.0, endTime: 15.4),
        Line(
            text: "Let's move the retro to Thursday afternoon, because half the team is traveling on Friday morning.",
            startTime: 20.0, endTime: 26.2),
        Line(text: "Great — can you post the new time in the channel?", startTime: 29.0, endTime: 31.8),
    ]

    private static let speakerCallMe = [
        // Bleed of the first Them line: one segment, ~1.2s late, two mishearings.
        Line(
            text: "I think we should shift the six on Tuesday and then watch the crash rate for a couple days.",
            startTime: 11.2, endTime: 16.5),
        // Genuine reply between the far end's turns.
        Line(text: "Agreed, I'll cut the release branch tomorrow morning.", startTime: 17.0, endTime: 19.4),
        // Bleed of the second Them line, split across two mic segments — the
        // engines segment independently, so one far-end sentence can land as two.
        Line(text: "Let's move the retro to Thursday afternoon.", startTime: 21.1, endTime: 24.3),
        Line(
            text: "Because half the team is unraveling on Friday morning.",
            startTime: 24.5, endTime: 27.9),
        // Genuine answer overlapping the far end's last line — real cross-talk on
        // a speaker call, different words at the same time.
        Line(text: "Sure, I'll post it right after we hang up.", startTime: 30.5, endTime: 33.0),
    ]

    @Test func speakerCallDropsExactlyTheBleedCopies() {
        let marked = BleedDetector.bleedOffsets(
            micLines: Self.speakerCallMe,
            systemLines: Self.speakerCallThem
        )
        #expect(marked == [0, 2, 3])
    }

    // MARK: - Fixture: in-person cross-talk

    /// Two people in one room, both on the mic; the system channel heard a shared
    /// screen's notification and a video clip's narration — words that never match
    /// what anyone in the room said. Simultaneous speech is everywhere in this
    /// fixture and none of it may drop: overlap only nominates, text convicts.
    private static let inPersonMe = [
        Line(
            text: "So the migration plan is three phases, we start with the read path.",
            startTime: 5.0, endTime: 9.2),
        // Cross-talk: interrupts the first speaker mid-sentence, different words.
        Line(text: "Wait, the read path first? I thought writes were the bottleneck.", startTime: 7.8, endTime: 11.5),
        Line(text: "Right, exactly.", startTime: 12.0, endTime: 12.9),
        Line(
            text: "Writes come second because we can shadow them behind the flag.",
            startTime: 13.0, endTime: 16.8),
    ]

    private static let inPersonThem = [
        // A shared screen's video clip, overlapping the whole exchange.
        Line(
            text: "In this demo we'll walk through the dashboard and its configuration options.",
            startTime: 6.0, endTime: 12.0),
        Line(text: "You have a meeting in five minutes.", startTime: 14.0, endTime: 15.6),
    ]

    @Test func inPersonCrossTalkDropsNothing() {
        let marked = BleedDetector.bleedOffsets(
            micLines: Self.inPersonMe,
            systemLines: Self.inPersonThem
        )
        #expect(marked.isEmpty)
    }

    @Test func silentSystemChannelDropsNothing() {
        // The pure in-person case: nothing came out of the machine, so there is
        // nothing to have bled, however people talked over each other on the mic.
        let marked = BleedDetector.bleedOffsets(micLines: Self.inPersonMe, systemLines: [])
        #expect(marked.isEmpty)
    }

    // MARK: - The decisions the thresholds encode

    @Test func verbatimEchoBackOfAWholePhraseSurvives() {
        // The hardest genuine case there is: a short clarifying repetition with no
        // framing words at all — five normalized words, inside the skew window,
        // similarity 1. Text can't save it and length can't save it; the timing
        // direction does: the human waited for the phrase to end before repeating
        // it, and bleed never starts after its source has finished playing.
        let them = [
            Line(text: "We should ship the fix on Tuesday.", startTime: 10.0, endTime: 13.6)
        ]
        let me = [
            Line(text: "Ship the fix on Tuesday?", startTime: 14.1, endTime: 15.8)
        ]
        #expect(BleedDetector.bleedOffsets(micLines: me, systemLines: them).isEmpty)
    }

    @Test func farEndRepeatingYourWordsIsNotBleed() {
        // The mirror image: the remote person reads your request back. The Me line
        // is the *original* here — it starts before its near-duplicate does, and a
        // copy can't precede its source, so the direction gate keeps it.
        let me = [
            Line(
                text: "Can you take the incident review this week instead of me?",
                startTime: 10.0, endTime: 12.4)
        ]
        let them = [
            Line(
                text: "Take the incident review this week instead of you — sure, happy to.",
                startTime: 13.0, endTime: 16.1)
        ]
        #expect(BleedDetector.bleedOffsets(micLines: me, systemLines: them).isEmpty)
    }

    @Test func trailingFragmentBleedIsStillCaught() {
        // The direction gate must not reintroduce misses: the mic engine can cut
        // its copy of a long far-end sentence so late that the fragment barely
        // overlaps the source and runs well past its end. Starting inside the
        // span — even just — is what makes it a copy rather than a reply.
        let them = [
            Line(
                text: "The rollout pauses automatically if the crash rate moves more than half a percent in either direction.",
                startTime: 40.0, endTime: 47.0)
        ]
        let me = [
            Line(
                text: "If the crash rate moves more than half a percent in either direction.",
                startTime: 46.6, endTime: 49.8)
        ]
        #expect(BleedDetector.bleedOffsets(micLines: me, systemLines: them) == [0])
    }

    @Test func quotingTheFarEndBackIsNotBleed() {
        // Repeating the far end's words back starts within the timing tolerance of
        // the line it quotes — the time gate can't save this one; the extra words
        // the speaker added have to.
        let them = [
            Line(
                text: "I think we should ship the fix on Tuesday and watch the crash rate.",
                startTime: 10.0, endTime: 14.0)
        ]
        let me = [
            Line(
                text: "So you're saying ship the fix on Tuesday, right?",
                startTime: 14.8, endTime: 17.2)
        ]
        #expect(BleedDetector.bleedOffsets(micLines: me, systemLines: them).isEmpty)
    }

    @Test func identicalShortAcknowledgementsSurvive() {
        // Both sides saying the same short thing at the same moment is ordinary
        // conversation — sign-offs especially. Text can't tell it from bleed, so
        // the length gate refuses to judge lines this short.
        let them = [
            Line(text: "Okay, thanks — bye!", startTime: 40.0, endTime: 41.2),
            Line(text: "Yeah, exactly.", startTime: 35.0, endTime: 35.9),
        ]
        let me = [
            Line(text: "Okay thanks, bye.", startTime: 40.3, endTime: 41.5),
            Line(text: "Yeah exactly.", startTime: 35.2, endTime: 36.0),
        ]
        #expect(BleedDetector.bleedOffsets(micLines: me, systemLines: them).isEmpty)
    }

    @Test func matchingTextOutsideTheTimingToleranceIsNotBleed() {
        // The same sentence a minute later is someone circling back to the topic,
        // not playback: bleed arrives within seconds, so time gates the candidates.
        let them = [
            Line(
                text: "We should ship the fix on Tuesday and watch the crash rate for a couple of days.",
                startTime: 10.0, endTime: 14.0)
        ]
        let me = [
            Line(
                text: "We should ship the fix on Tuesday and watch the crash rate for a couple of days.",
                startTime: 75.0, endTime: 79.0)
        ]
        #expect(BleedDetector.bleedOffsets(micLines: me, systemLines: them).isEmpty)
    }

    @Test func bleedAtMaximumMeasuredSkewIsStillCaught() {
        // The far edge of the realistic window: the mic's copy lands a full two
        // seconds after the tap's, past the end of a short utterance.
        let them = [
            Line(
                text: "Can you take the incident review this week instead of me?",
                startTime: 8.0, endTime: 10.4)
        ]
        let me = [
            Line(
                text: "Can you take the incident review this week instead of me?",
                startTime: 10.0, endTime: 12.5)
        ]
        #expect(BleedDetector.bleedOffsets(micLines: me, systemLines: them) == [0])
    }

    @Test func normalizationIgnoresCaseAndPunctuation() {
        #expect(
            BleedDetector.normalizedWords("Okay — thanks, BYE!") == ["okay", "thanks", "bye"]
        )
    }

    @Test func similarityIsForgivingAtTheEndsOfTheReference() {
        // The candidate matching a window inside a longer reference costs nothing
        // for what the reference says before and after it.
        let candidate = BleedDetector.normalizedWords("ship the fix on Tuesday")
        let reference = BleedDetector.normalizedWords(
            "I really do think we should ship the fix on Tuesday and then watch the crash rate")
        #expect(BleedDetector.similarity(of: candidate, toReferenceOf: reference) == 1)
    }

    @Test func similarityChargesForTheCandidatesOwnExtraWords() {
        let candidate = BleedDetector.normalizedWords("so you're saying ship the fix on Tuesday right")
        let reference = BleedDetector.normalizedWords("we should ship the fix on Tuesday")
        #expect(
            BleedDetector.similarity(of: candidate, toReferenceOf: reference)
                < BleedDetector.similarityThreshold)
    }

    // MARK: - Marking on the model

    private func makeSpeakerCallMeeting() -> Meeting {
        let meeting = Meeting(title: "Speaker call")
        var segments: [TranscriptSegment] = []
        for line in Self.speakerCallThem {
            segments.append(
                TranscriptSegment(
                    channel: .them, text: line.text, startTime: line.startTime, endTime: line.endTime))
        }
        for line in Self.speakerCallMe {
            segments.append(
                TranscriptSegment(
                    channel: .me, text: line.text, startTime: line.startTime, endTime: line.endTime))
        }
        meeting.segments = segments
        return meeting
    }

    /// The mic segments of ``makeSpeakerCallMeeting()``, in the fixture's order.
    private func micSegments(of meeting: Meeting) -> [TranscriptSegment] {
        meeting.segments.filter { $0.channel == .me }.sorted { $0.startTime < $1.startTime }
    }

    @Test func markBleedSegmentsFlagsTheMicCopies() {
        let meeting = makeSpeakerCallMeeting()
        let changed = meeting.markBleedSegments()

        #expect(changed == 3)
        #expect(micSegments(of: meeting).map(\.isBleed) == [true, false, true, true, false])
        #expect(meeting.segments.filter { $0.channel == .them }.allSatisfy { !$0.isBleed })
    }

    @Test func markBleedSegmentsIsIdempotent() {
        let meeting = makeSpeakerCallMeeting()
        meeting.markBleedSegments()
        let flags = micSegments(of: meeting).map(\.isBleed)

        #expect(meeting.markBleedSegments() == 0)
        #expect(micSegments(of: meeting).map(\.isBleed) == flags)
    }

    @Test func markBleedSegmentsHealsAStaleVerdict() {
        // Text and timestamps never change after recording, so a re-run owns the
        // whole verdict — a flag some earlier pass set on what this pass judges
        // genuine comes back off, rather than accumulating forever.
        let meeting = makeSpeakerCallMeeting()
        let genuine = micSegments(of: meeting)[1]
        genuine.isBleed = true

        meeting.markBleedSegments()
        #expect(!genuine.isBleed)
    }

    @Test func markBleedSegmentsLeavesHumanSettledLinesAlone() {
        // A person renamed one bleed line and confirmed another before processing
        // ever ran (or between runs): their word outranks the detector, same as it
        // outranks the diarizer.
        let meeting = makeSpeakerCallMeeting()
        let mic = micSegments(of: meeting)
        mic[0].assignSpeaker("Carter")
        mic[2].speakerLabel = "Carter"
        mic[2].isSpeakerLabelConfirmed = true

        let changed = meeting.markBleedSegments()
        #expect(changed == 1)
        #expect(mic.map(\.isBleed) == [false, false, false, true, false])
    }

    // MARK: - Marked segments stay out of every consumer

    @Test func bleedIsExcludedFromTranscriptTextAndDisplaySurfaces() {
        let meeting = makeSpeakerCallMeeting()
        meeting.markBleedSegments()

        // The summarizer and title generator read this string: each remote
        // utterance must appear once, on the Them side.
        let transcript = meeting.transcriptText
        #expect(!transcript.contains("shift the six"))
        #expect(!transcript.contains("[Me] Let's move the retro"))
        #expect(transcript.contains("[Them] I think we should ship the fix"))
        #expect(transcript.contains("[Me] Agreed, I'll cut the release branch tomorrow morning."))

        // The speakers panel and its talk-time math: "Me" keeps only the two
        // genuine lines, so the far end's airtime isn't credited to the user.
        let me = meeting.speakerSummaries.first { $0.label == "Me" }
        #expect(me?.lineCount == 2)

        // The timeline never paints the mic's copy of the far end's seconds.
        #expect(meeting.speakerTimeline.count(where: { $0.label == "Me" }) == 2)

        // Enrollment excerpts must never carry the far end's voice under "Me".
        if let me {
            let bleedStarts = Set(
                micSegments(of: meeting).filter(\.isBleed).map(\.startTime))
            #expect(meeting.ranges(for: me).allSatisfy { !bleedStarts.contains($0.start) })
        }
    }

    @Test func bleedIsExcludedFromExport() {
        let meeting = makeSpeakerCallMeeting()
        meeting.markBleedSegments()

        let export = meeting.export(ownerNames: [])
        #expect(export.segments.count == Self.speakerCallThem.count + 2)
        // No mic segment in the export carries far-end text — the mis-attributed
        // `isOwner: true` copy is exactly what an agent must never receive.
        #expect(
            export.segments.filter { $0.channel == .me }.map(\.text) == [
                "Agreed, I'll cut the release branch tomorrow morning.",
                "Sure, I'll post it right after we hang up.",
            ])
    }
}
