import CheerioKit
import SwiftData
import SwiftUI

/// What replaces the old bare "No meeting selected" placeholder (#124): upcoming
/// calendar events, this week's activity, the two start actions, and a rotating tip
/// — so the biggest pane in the window earns its space on the day nothing is
/// selected, instead of sitting on one inert sentence.
struct EmptyStateDashboardView: View {
    @Binding var selection: Meeting?
    /// Owned by ``ContentView``, not this view — the same instance also gates the
    /// enrollment banner ``ContentView/detail`` shows above a *selected* meeting, so
    /// dismissing it in either place has to be the one flag both read.
    @Binding var enrollmentPromptDismissed: Bool

    @Environment(CaptureSession.self) private var session
    @Environment(\.modelContext) private var context
    @Query(sort: \Meeting.startedAt, order: .reverse) private var meetings: [Meeting]
    @Query(sort: \EnrolledSpeaker.enrolledAt) private var enrolledSpeakers: [EnrolledSpeaker]

    /// Refreshed on appearance rather than bound to a live poll — unlike the
    /// sidebar's "happening right now" banner, this list isn't chasing a countdown,
    /// so it only needs to be current for whoever's looking at it *now*.
    @State private var upcoming: [CalendarMeeting] = []

    private var stats: MeetingActivityStats {
        MeetingActivityStats.compute(from: meetings)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.x6) {
                if enrolledSpeakers.isEmpty {
                    VoiceEnrollmentPrompt(
                        isDismissed: enrollmentPromptDismissed,
                        onDismiss: { enrollmentPromptDismissed = true }
                    )
                }

                actions

                // Calendar access denied or never granted reads exactly like "no
                // events in the next week" here — an empty array either way, and
                // never an error or a nag for something the walkthrough already
                // offered and the user may have deliberately skipped.
                if !upcoming.isEmpty {
                    upcomingSection
                }

                statsSection

                tip
            }
            .padding(Theme.Space.x8)
            .frame(maxWidth: 480, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .task {
            // `hasAccess` starts false on a fresh launch, and `ContentView`'s own
            // refresh is a separate `.task` racing this one — without refreshing
            // here too, a dashboard that renders before that one lands reads "no
            // access" and never asks again, showing an empty section forever even
            // once access is actually granted. `refreshAccessStatus()` never
            // prompts, so calling it again here costs nothing when the other
            // `.task` already won the race.
            await CalendarService.shared.refreshAccessStatus()
            upcoming = await CalendarService.shared.upcomingMeetings()
        }
    }

    /// Same two entry points the sidebar offers, going through the same
    /// ``RecordingStartFlow`` — never a second implementation of "check the mic
    /// permission, then start." Disabled together whenever the session isn't idle,
    /// rather than hidden: a dashboard that's only visible while idle in the first
    /// place would never actually show these disabled, but the buttons still ought
    /// to say plainly why they don't do anything on the rare frame they might.
    private var actions: some View {
        HStack(spacing: Theme.Space.x3) {
            Button {
                RecordingStartFlow.start(kind: .meeting, session: session, context: context, selection: $selection)
            } label: {
                Label("Start recording", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.state != .idle)

            Button {
                RecordingStartFlow.start(kind: .directive, session: session, context: context, selection: $selection)
            } label: {
                Label("Give Direction…", systemImage: "text.bubble")
            }
            .disabled(session.state != .idle)
        }
    }

    private var upcomingSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x2) {
            Text("Upcoming meetings").chText(.sectionHeading)
            VStack(alignment: .leading, spacing: Theme.Space.x1) {
                ForEach(upcoming) { event in
                    HStack {
                        Text(event.title).chText(.meetingTitle)
                        Spacer()
                        Text(event.startDate, format: .dateTime.weekday(.abbreviated).hour().minute())
                            .chText(.caption)
                    }
                }
            }
        }
    }

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x2) {
            Text("This week").chText(.sectionHeading)
            VStack(alignment: .leading, spacing: Theme.Space.x1) {
                statRow("Meetings", "\(stats.meetingsThisWeek)")
                statRow("Minutes transcribed", "\(stats.minutesTranscribedThisWeek)")
                statRow("Open follow-ups", "\(stats.openFollowUps)")
            }
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).chText(.caption)
            Spacer()
            Text(value).chText(.notesBody)
        }
    }

    private var tip: some View {
        Label {
            Text(DashboardTip.current.text)
        } icon: {
            Image(systemName: "lightbulb")
        }
        .chText(.caption)
        // One element, not the Label's default children: the lightbulb is
        // decorative, and SwiftUI reports the inner text's accessibility frame
        // offset from where the Label actually renders it — measured on the CI
        // runner (#142), the contrast audit sampled a blank strip while the tip
        // drew just above it. The combined element's frame covers the Label's
        // real rendered bounds, so the audit measures the tip's own pixels.
        .accessibilityElement(children: .combine)
    }
}
