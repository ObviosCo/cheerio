import CheerioKit
import Foundation
import SwiftData

// Writes the demo store the screenshot harness photographs.
//
//     swift run SeedDemoStore --container <dir>
//
// `<dir>` is the app's Application Support container inside a scratch HOME — i.e.
// `<scratch>/Library/Application Support/co.obvios.cheerio.mac`. The store file, and the
// per-meeting audio folders the detail view's buttons key off, are written into it.
//
// Everything below is invented. None of it comes from anyone's real store, and it
// must stay that way: these captures ship on a public website.
//
// The action items go through `ActionItem.resolved(from:ownerNames:)` rather than
// being constructed directly, which is both the only public way to make one and the
// point — the demo notes are vetted by the same rule production notes are, so a
// screenshot can't show a trust state the app would never produce.

// MARK: - Arguments

let arguments = Array(CommandLine.arguments.dropFirst())
guard let containerIndex = arguments.firstIndex(of: "--container"),
    containerIndex + 1 < arguments.count
else {
    FileHandle.standardError.write(Data("usage: SeedDemoStore --container <dir>\n".utf8))
    exit(2)
}
let container = URL(filePath: arguments[containerIndex + 1], directoryHint: .isDirectory)

// MARK: - Cast

/// The enrolled voice marked "me". Its name is what makes an action item actionable
/// rather than a follow-up, so it has to match the transcript labels below exactly.
let owner = "Sam Whitfield"
let ownerNames: Set<String> = [owner]

// MARK: - Demo content

/// One line of transcript.
struct Line {
    let speaker: String
    let channel: SpeakerChannel
    let text: String
    /// Renders the "named by hand" marker, and shows that a correction survives.
    var isManual = false
}

struct Demo {
    let title: String
    var kind: MeetingKind = .meeting
    /// Days before now, so the library reads as lived-in whenever it's captured.
    let daysAgo: Int
    let hour: Int
    let minute: Int
    let minutes: Int
    var roughNotes = ""
    var summary = ""
    var keyPoints: [String] = []
    var decisions: [String] = []
    var drafts: [ActionItemDraft] = []
    var lines: [Line] = []
    var participants: [String]?
    /// Audio still on disk. Only worth setting inside the retention window (7 days by
    /// default) — the app purges anything older at launch and nils this out anyway.
    var hasAudio = false
}

let demos: [Demo] = [
    Demo(
        title: "Wednesday sync — release planning",
        daysAgo: 2,
        hour: 10,
        minute: 2,
        minutes: 34,
        roughNotes: """
            importer still 4x slower on the big fixture
            19th is fixed — WWDC week after, nobody around
            ask dana re: northgate timeline
            """,
        summary: """
            The team cut 2.4 back to what can ship on the 19th. The batch importer \
            missed its performance target on the 40,000-row fixture and comes out of \
            the release rather than holding it; the export format change stays in, \
            with a migration note. Support cover for release day is still unassigned.
            """,
        keyPoints: [
            "The importer is roughly four times slower than the old path on the 40,000-row fixture — the regression is in the per-row validation, not the parser.",
            "The 19th is fixed: the week after is a conference week and nobody is around to watch a release.",
            "The export format change is already in two customers' hands through the beta, so pulling it now costs more than shipping it.",
            "Northgate's pilot timeline assumed the importer, so their plan needs redoing either way.",
        ],
        decisions: [
            "Batch importer comes out of 2.4 and relands behind a flag in 2.5.",
            "Ship the export format change in 2.4 with a migration note in the release notes.",
            "Release date stays the 19th.",
        ],
        drafts: [
            ActionItemDraft(
                task: "Cut the batch importer from 2.4 and reland it behind a flag in 2.5",
                owner: "Sam Whitfield", disposition: .actionable),
            ActionItemDraft(
                task: "Write the migration note for the changed export format",
                owner: "Sam Whitfield", disposition: .actionable),
            ActionItemDraft(
                task: "Re-run the import benchmark on the 40,000-row fixture before Friday",
                owner: "Sam Whitfield", disposition: .actionable),
            ActionItemDraft(
                task: "Send Northgate a revised pilot timeline without the importer",
                owner: "Dana Okafor", disposition: .followUp),
            ActionItemDraft(
                task: "Confirm whether the quit crash is the same one as issue 212",
                owner: "Marcus Feld", disposition: .followUp),
            ActionItemDraft(
                task: "Decide who covers support on release day",
                owner: "the team", disposition: .followUp),
        ],
        lines: [
            Line(
                speaker: owner, channel: .me,
                text: "Right, let's start with the importer, because I think that's the thing that decides the rest of the meeting."),
            Line(
                speaker: "Priya Raman", channel: .them,
                text:
                    "It's still four times slower on the forty thousand row fixture. I spent yesterday on it and the time isn't where I thought it was."
            ),
            Line(speaker: owner, channel: .me, text: "Not the parser?"),
            Line(
                speaker: "Priya Raman", channel: .them,
                text: "No, the parser's fine. It's the per row validation — we're re-reading the schema for every row instead of once."),
            Line(
                speaker: "Marcus Feld", channel: .them,
                text: "That's fixable, but not by the nineteenth. I'd want a week on it and then a week of it sitting in the beta."),
            Line(
                speaker: owner, channel: .me, text: "Then it comes out. I'd rather ship a smaller release on the date than move the date."),
            Line(
                speaker: "Dana Okafor", channel: .them,
                text: "Northgate's plan has the importer in it. Their pilot timeline was written around it, so that changes either way."),
            Line(speaker: owner, channel: .me, text: "Can you redo the timeline without it and send it to them this week?"),
            Line(
                speaker: "Dana Okafor", channel: .them,
                text: "Yes. I'll send it before Thursday so they've got it ahead of their own planning call."),
            Line(
                speaker: "Priya Raman", channel: .them,
                text: "What about the export format? That's already gone out to two customers in the beta."),
            Line(
                speaker: owner, channel: .me,
                text:
                    "That stays. Pulling something people are already writing against is worse than the change itself. I'll write the migration note."
            ),
            Line(
                speaker: "Marcus Feld", channel: .them,
                text: "There's also the crash on quit. I think it's the same one as two twelve but I haven't proved it.", isManual: true),
            Line(
                speaker: "Marcus Feld", channel: .them,
                text: "I'll get a symbolicated log off the machine it reproduces on and say for certain."),
            Line(
                speaker: owner, channel: .me,
                text:
                    "Fine. And I'll re-run the benchmark on the big fixture on Friday so we know where the flagged version actually lands."),
            Line(
                speaker: "Priya Raman", channel: .them,
                text: "Last thing — who's on support on the nineteenth? Because I'm out that afternoon."),
            Line(
                speaker: owner, channel: .me,
                text: "Let's sort that out on Friday when we know who's around. Nobody volunteer now, you'll regret it."),
        ],
        participants: [owner, "Priya Raman", "Marcus Feld"],
        hasAudio: true
    ),

    Demo(
        title: "Call with Dana about the pilot",
        daysAgo: 4,
        hour: 15,
        minute: 30,
        minutes: 22,
        roughNotes: "pilot ends 6th — they want the export before then",
        summary: """
            Dana walked through where the Northgate pilot stands. Two of the four \
            stores are using it daily, the other two are waiting on the export. The \
            pilot ends on the 6th and the renewal conversation needs the export \
            working before it.
            """,
        keyPoints: [
            "Two of four pilot stores are in daily use; the other two are blocked on the CSV export.",
            "The pilot ends on the 6th, and the renewal conversation is scheduled the same week.",
            "Their objection is the manual step at the end of the day, not the price.",
        ],
        decisions: [
            "Export ships before the pilot ends, even if it's the narrow version."
        ],
        drafts: [
            ActionItemDraft(
                task: "Ship the narrow CSV export ahead of the pilot review",
                owner: "Sam Whitfield", disposition: .actionable),
            ActionItemDraft(
                task: "Put a written summary of the pilot in front of the two blocked stores",
                owner: "Dana Okafor", disposition: .followUp),
        ],
        lines: [
            Line(speaker: owner, channel: .me, text: "How many of the four are actually using it?"),
            Line(
                speaker: "Dana Okafor", channel: .them,
                text:
                    "Two, every day. The other two opened it once and went back to the spreadsheet because they can't get the numbers out at close."
            ),
            Line(speaker: owner, channel: .me, text: "So it's the export. That's the whole objection?"),
            Line(
                speaker: "Dana Okafor", channel: .them, text: "It's the manual step at the end of the day. Nobody's mentioned price once."),
            Line(
                speaker: owner, channel: .me,
                text: "Then I'll ship the narrow version of the export before the sixth and we can widen it later."),
            Line(
                speaker: "Dana Okafor", channel: .them,
                text:
                    "That'd change the renewal conversation completely. I'll write up where the pilot got to for the two stores that stalled."
            ),
        ],
        participants: [owner, "Dana Okafor"],
        hasAudio: true
    ),

    Demo(
        title: "Direction — what to do with the crash reports",
        kind: .directive,
        daysAgo: 5,
        hour: 8,
        minute: 47,
        minutes: 6,
        summary: """
            A directive session: instructions for triaging the backlog of crash \
            reports, dictated alone rather than in a meeting. Group by stack \
            signature, ignore anything below three occurrences, and open one issue per \
            group with the symbolicated trace attached.
            """,
        keyPoints: [
            "Group the reports by stack signature rather than by the reported symptom.",
            "Anything under three occurrences goes in a list, not an issue.",
            "Each issue gets the symbolicated trace and the OS build attached.",
        ],
        decisions: [],
        drafts: [
            ActionItemDraft(
                task: "Group the crash backlog by stack signature and open one issue per group",
                owner: "Sam Whitfield", disposition: .actionable),
            ActionItemDraft(
                task: "Attach the symbolicated trace and OS build to each issue",
                owner: "Sam Whitfield", disposition: .actionable),
        ],
        lines: [
            Line(speaker: owner, channel: .me, text: "This is for whoever picks up the crash backlog, me included, next week."),
            Line(
                speaker: owner, channel: .me,
                text:
                    "Group them by stack signature, not by what the person said happened. Half of the reports describe the same crash three different ways."
            ),
            Line(
                speaker: owner, channel: .me,
                text: "Anything with fewer than three occurrences goes in a list at the bottom. Don't open an issue for it yet."),
            Line(
                speaker: owner, channel: .me,
                text:
                    "Every issue you do open gets the symbolicated trace and the OS build on it, because without those it's not actionable and it'll sit there for a month."
            ),
        ],
        participants: [owner],
        hasAudio: true
    ),

    Demo(
        title: "1:1 with Priya",
        daysAgo: 8,
        hour: 9,
        minute: 15,
        minutes: 27,
        summary: """
            Priya wants more of the performance work and less of the intake rota. \
            Agreed to move her off intake after this cycle and to write down what \
            "senior" means here before the next review, because the current answer is \
            whatever the last conversation said.
            """,
        keyPoints: [
            "Intake is eating roughly a day and a half a week of her time.",
            "The performance work is the part she wants more of, and it's also the part nobody else is doing.",
            "There's no written definition of the next level, which makes the review conversation guesswork.",
        ],
        decisions: [
            "Priya comes off the intake rota at the end of this cycle."
        ],
        drafts: [
            ActionItemDraft(
                task: "Write down what the next level actually requires before the review",
                owner: "Sam Whitfield", disposition: .actionable),
            ActionItemDraft(
                task: "Rework the intake rota without Priya on it",
                owner: "Sam Whitfield", disposition: .followUp),
        ],
        lines: [
            Line(speaker: "Priya Raman", channel: .them, text: "Intake is about a day and a half a week now. It used to be half a day."),
            Line(speaker: owner, channel: .me, text: "That's more than I thought. Is it volume or is it that the reports are worse?"),
            Line(
                speaker: "Priya Raman", channel: .them,
                text:
                    "Volume. The reports are fine. It's just that there are twice as many of them and I'm the only one who reads them properly."
            ),
            Line(
                speaker: owner, channel: .me,
                text: "Come off the rota at the end of the cycle. I'll redo it without you and we'll see what breaks."),
            Line(
                speaker: "Priya Raman", channel: .them,
                text: "The other thing is the review. I genuinely don't know what the bar is, and I don't think you do either."),
            Line(
                speaker: owner, channel: .me,
                text: "That's fair. I'll write it down before the next one rather than making it up in the room."),
        ],
        participants: [owner, "Priya Raman"]
    ),

    Demo(
        title: "Design review — enrollment flow",
        daysAgo: 11,
        hour: 13,
        minute: 0,
        minutes: 45,
        roughNotes: "30s minimum is the thing people trip on",
        summary: """
            Reviewed the enrollment flow. The 30-second sample requirement is where \
            people give up, so the screen has to earn that half minute rather than \
            demand it. Agreed to show the sample length as progress and to let a short \
            sample save with a warning rather than blocking it.
            """,
        keyPoints: [
            "Nobody reads the explanation above the record button; they press it and stop early.",
            "A too-short sample is worse than no sample, because the failure shows up meetings later.",
            "Showing elapsed seconds against the recommendation turns a rule into feedback.",
        ],
        decisions: [
            "Short samples save with a warning instead of being rejected.",
            "The recorder shows progress toward the recommended length.",
        ],
        drafts: [
            ActionItemDraft(
                task: "Show elapsed seconds against the recommended length in the recorder",
                owner: "Sam Whitfield", disposition: .actionable),
            ActionItemDraft(
                task: "Redraw the enrollment screen with the warning state included",
                owner: "Wren Halliday", disposition: .followUp),
        ],
        lines: [
            Line(
                speaker: "Wren Halliday", channel: .them,
                text: "Watch what people actually do — they press record, say their name, and stop. Four seconds."),
            Line(speaker: owner, channel: .me, text: "And then it fails three meetings later and looks like the model is bad."),
            Line(
                speaker: "Wren Halliday", channel: .them,
                text: "Right. So show them the thirty seconds filling up. Don't tell them about it in a paragraph they won't read."),
            Line(
                speaker: owner, channel: .me,
                text: "I'll put the counter in. And a short sample should still save — just with the warning on it."),
        ],
        participants: [owner, "Wren Halliday"]
    ),

    Demo(
        title: "Support triage — Thursday",
        daysAgo: 15,
        hour: 11,
        minute: 20,
        minutes: 18,
        summary: """
            Worked through the week's open tickets. Two are the same import bug, one \
            is a licensing question that needs a real answer rather than a link, and \
            the rest are configuration.
            """,
        keyPoints: [
            "Tickets 118 and 121 are one bug reported twice.",
            "The licensing question keeps coming back, which means the answer isn't where people look.",
        ],
        decisions: [
            "Merge 121 into 118."
        ],
        drafts: [
            ActionItemDraft(
                task: "Merge ticket 121 into 118 and reply once",
                owner: "Sam Whitfield", disposition: .actionable),
            ActionItemDraft(
                task: "Put the licensing answer somewhere findable",
                owner: "Marcus Feld", disposition: .followUp),
        ],
        lines: [
            Line(
                speaker: "Marcus Feld", channel: .them,
                text: "One eighteen and one twenty-one are the same thing. Different words, same stack."),
            Line(speaker: owner, channel: .me, text: "Merge them and answer once. What's the licensing one?"),
            Line(
                speaker: "Marcus Feld", channel: .them,
                text:
                    "Third time this month someone's asked whether they can use it at work. The answer's in the readme, which is apparently nowhere."
            ),
        ],
        participants: [owner, "Marcus Feld"]
    ),

    Demo(
        title: "Northgate Supply — pilot kickoff",
        daysAgo: 21,
        hour: 14,
        minute: 0,
        minutes: 51,
        summary: """
            Kickoff for the four-store pilot. Ran through what the pilot is measuring, \
            who at Northgate is responsible for each store, and what happens at the \
            end of it. Their close-of-day process is the thing to watch.
            """,
        keyPoints: [
            "Four stores, six weeks, one named person per store.",
            "The measure is whether close-of-day gets faster, not whether people like it.",
            "Northgate wants a written summary at the end, not a call.",
        ],
        decisions: [
            "Pilot runs six weeks and ends with a written summary."
        ],
        drafts: [
            ActionItemDraft(
                task: "Set up the four store accounts before Monday",
                owner: "Sam Whitfield", disposition: .actionable),
            ActionItemDraft(
                task: "Get the named contact for the fourth store",
                owner: "Dana Okafor", disposition: .followUp),
        ],
        lines: [
            Line(
                speaker: "Dana Okafor", channel: .them,
                text: "Four stores, six weeks. Three have a named person, the fourth is still being argued about internally."),
            Line(speaker: owner, channel: .me, text: "I'll have the accounts up before Monday so nobody's waiting on us."),
            Line(
                speaker: "Dana Okafor", channel: .them,
                text: "And what we're measuring is close of day. If that doesn't get faster, none of the rest matters to them."),
        ],
        participants: [owner, "Dana Okafor"]
    ),
]

// MARK: - Write

let storeURL = container.appending(path: "default.store")
try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
// Repeatability: a second run photographs the same library, not a doubled one.
for suffix in ["", "-wal", "-shm"] {
    try? FileManager.default.removeItem(at: container.appending(path: "default.store\(suffix)"))
}

let modelContainer = try ModelContainer(
    for: Meeting.self, TranscriptSegment.self, EnrolledSpeaker.self,
    configurations: ModelConfiguration(url: storeURL)
)
let context = ModelContext(modelContainer)

let calendar = Calendar.current
let now = Date.now

for (index, speaker) in [(owner, 41.0), ("Priya Raman", 36.0), ("Marcus Feld", 33.0), ("Dana Okafor", 22.0)]
    .enumerated()
{
    let (name, duration) = speaker
    let enrolled = EnrolledSpeaker(
        name: name,
        audioPath: "Speakers/demo-\(index).caf",
        duration: duration,
        // Enrollment order is the roster's only ordering, so space these out.
        enrolledAt: now.addingTimeInterval(-Double(40 - index * 3) * 86_400)
    )
    enrolled.isMe = name == owner
    context.insert(enrolled)
}

for demo in demos {
    let day = calendar.date(byAdding: .day, value: -demo.daysAgo, to: now) ?? now
    let startedAt =
        calendar.date(bySettingHour: demo.hour, minute: demo.minute, second: 0, of: day) ?? day

    let meeting = Meeting(title: demo.title, startedAt: startedAt)
    meeting.kind = demo.kind
    meeting.endedAt = startedAt.addingTimeInterval(Double(demo.minutes) * 60)
    meeting.roughNotes = demo.roughNotes
    meeting.participantNames = demo.participants

    let items = ActionItem.resolved(from: demo.drafts, ownerNames: ownerNames)
    meeting.actionItems = items
    meeting.enhancedNotes =
        EnhancedNotes(
            summary: demo.summary,
            keyPoints: demo.keyPoints,
            decisions: demo.decisions,
            actionItems: items
        ).markdown

    if demo.hasAudio {
        let relativePath = "Meetings/\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            at: container.appending(path: relativePath, directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        meeting.audioDirectory = relativePath
    }

    context.insert(meeting)

    // Lines run back to back at a plausible speaking rate, so the speakers panel's
    // per-person second counts add up to something believable.
    var offset: TimeInterval = 4
    for line in demo.lines {
        let seconds = max(3.0, Double(line.text.count) / 15.0)
        let segment = TranscriptSegment(
            channel: line.channel,
            text: line.text,
            startTime: offset,
            endTime: offset + seconds
        )
        segment.speakerLabel = line.speaker
        segment.isSpeakerLabelManual = line.isManual
        segment.meeting = meeting
        context.insert(segment)
        offset += seconds + 1.2
    }
}

try context.save()
print("Seeded \(demos.count) demo meetings into \(storeURL.path)")
