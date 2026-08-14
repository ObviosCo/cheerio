import CheerioKit
import SwiftData
import SwiftUI

/// Which fixture state ``RecordingSurfacePreview`` draws, as the raw value of
/// `-screenshotRecordingPreview`.
///
/// Two, because they're the two the live surface has that nothing else in the app
/// repeats: mid-recording, and the post-meeting hold (#136) with its countdown,
/// kind switch and callback controls. `.finishing` differs from `.recording` only
/// by the phase indicator (#173) taking the ring's place and the toolbar button
/// going disabled, so it would mostly re-audit chrome the system draws.
enum RecordingPreviewVariant: String {
    case recording
    case holding
}

/// Renders ``RecordingSurface`` from fixture values, for the accessibility audits
/// and the screenshot harness (#164).
///
/// This is the answer to a surface that only exists while two capture channels are
/// running: the audits cannot start a recording — `ScreenshotMode`'s charter is
/// that nothing there can — and the alternative, a seam that made `CaptureSession`
/// report a state it isn't in, would put a fake recording state within one bug of
/// the menu bar, `UpdatePolicy`'s update gating and the deletion guards, all of
/// which key off exactly that property. Nothing here touches the session: it stays
/// `.idle` for the whole launch, and this view hands `RecordingSurface` the values
/// a live session would have handed it.
///
/// The store it renders against is in memory and thrown away with the process, so
/// the fixture meeting and voices can't reach the seeded demo store, let alone
/// anyone's real one. Its every action closure is empty — there is no recording to
/// stop and no processing to confirm.
struct RecordingSurfacePreview: View {
    let variant: RecordingPreviewVariant

    /// Live state the surface writes back through. Fixture values, held here so the
    /// controls behave like controls if anyone drives them by hand.
    @State private var roughNotes = """
        importer regression — per-row validation, not the parser
        19th is fixed, conference week after
        ask dana about the northgate timeline
        """
    @State private var holdKind: MeetingKind = .meeting
    @State private var holdRunsCallback = true
    @State private var holdTriggerID: UUID?
    @State private var holdCallbackPrompt = ""
    /// Relative to launch rather than a fixed instant: the elapsed timer and the
    /// hold countdown both read from these, and a deadline baked in at build time
    /// would render as an expired hold counting *up*.
    @State private var startedAt = Date.now.addingTimeInterval(-8 * 60 - 12)
    @State private var holdDeadline = Date.now.addingTimeInterval(4 * 60)

    var body: some View {
        RecordingSurface(
            state: variant == .holding ? .holding : .recording,
            meeting: RecordingPreviewFixture.meeting,
            processingPhaseLabel: nil,
            startedAt: startedAt,
            liveLines: RecordingPreviewFixture.lines,
            // Capture is over in `.holding`, so nothing is still forming — the
            // half-opacity volatile line belongs to the recording state only.
            volatileLine: variant == .holding ? nil : RecordingPreviewFixture.volatileLine,
            holdDeadline: variant == .holding ? holdDeadline : nil,
            // On in the recording variant because the banner is otherwise audited
            // nowhere: it shows once ever, on a real first recording after a
            // skipped enrollment.
            showsEnrollmentNudge: variant == .recording,
            roughNotes: $roughNotes,
            holdKind: $holdKind,
            holdRunsCallback: $holdRunsCallback,
            holdTriggerID: $holdTriggerID,
            holdCallbackPrompt: $holdCallbackPrompt,
            onProcessNow: {},
            onStop: {},
            onTitleSubmit: {},
            onAddVoice: {},
            onDismissEnrollmentNudge: {}
        )
        // The fixture store, not the seeded one: `ParticipantRosterMenu` runs its
        // own `@Query` for enrolled voices, and this keeps the meeting it edits
        // out of any store that outlives the process.
        .modelContainer(RecordingPreviewFixture.container)
    }
}

/// The fixture store behind ``RecordingSurfacePreview`` — one meeting, a roster,
/// and a transcript, built once per launch.
///
/// In memory (`isStoredInMemoryOnly`), so the meeting whose title the surface
/// binds to and the roster the menu writes exist only for as long as the process
/// does. The names and lines come from the same invented cast as the demo store
/// (`Scripts/screenshots/SeedDemoStore`) — nothing here may ever come from a real
/// meeting; these get photographed.
@MainActor
private enum RecordingPreviewFixture {
    static let container: ModelContainer = {
        do {
            return try ModelContainer(
                for: Meeting.self, TranscriptSegment.self, EnrolledSpeaker.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        } catch {
            // Only reachable if an in-memory container can't be opened at all,
            // which would mean the schema itself is broken — and this only ever
            // runs under a launch argument no real launch passes.
            fatalError("Couldn't open the recording preview's in-memory store: \(error)")
        }
    }()

    static let meeting: Meeting = {
        let meeting = Meeting(title: "Wednesday sync — release planning")
        let context = container.mainContext
        context.insert(meeting)
        for (name, isMe) in [("Sam Whitfield", true), ("Priya Raman", false), ("Marcus Feld", false)] {
            let speaker = EnrolledSpeaker(name: name, audioPath: "", duration: 34)
            speaker.isMe = isMe
            context.insert(speaker)
        }
        meeting.participantNames = ["Sam Whitfield", "Priya Raman", "Marcus Feld"]
        return meeting
    }()

    /// Finalized lines, both channels, with start times spread across minutes so
    /// the sparse mm:ss stamps (#130) render too.
    static let lines: [TranscriptionUpdate] = [
        line(.me, 8, "Right, let's start with the importer, because I think that's what decides the rest of the meeting."),
        line(
            .them, 21,
            "It's still four times slower on the forty thousand row fixture. I spent yesterday on it and the time isn't where I thought it was."
        ),
        line(.me, 63, "Not the parser?"),
        line(
            .them, 71,
            "No, the parser's fine. It's the per row validation — we're re-reading the schema for every row instead of once."),
        line(.them, 128, "That's fixable, but not by the nineteenth. I'd want a week on it and a week of it sitting in the beta."),
        line(.me, 143, "Then it comes out. I'd rather ship a smaller release on the date than move the date."),
        line(.them, 187, "Northgate's plan has the importer in it, so their pilot timeline changes either way."),
    ]

    /// The line still forming, drawn at half opacity by the surface.
    static let volatileLine = TranscriptionUpdate(
        channel: .me, text: "Can you redo the timeline without it and send it to them",
        isFinal: false, startTime: 201, endTime: 205
    )

    private static func line(_ channel: SpeakerChannel, _ startTime: TimeInterval, _ text: String) -> TranscriptionUpdate {
        TranscriptionUpdate(channel: channel, text: text, isFinal: true, startTime: startTime, endTime: startTime + 6)
    }
}
