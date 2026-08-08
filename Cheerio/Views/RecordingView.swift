import CheerioKit
import SwiftUI

/// Live view during a meeting: transcript on the left, rough-notes
/// scratchpad on the right (the Granola pattern).
struct RecordingView: View {
    @Environment(CaptureSession.self) private var session
    @Environment(\.modelContext) private var context

    var body: some View {
        @Bindable var session = session

        VStack(spacing: 0) {
            // Renameable in place: the title is often wrong at the moment you notice
            // it — a calendar match that didn't apply, or a placeholder timestamp.
            if let meeting = session.meeting {
                @Bindable var meeting = meeting
                HStack(spacing: 8) {
                    // Routed through `rename(to:)` rather than a direct `$meeting.title`
                    // binding: a title typed here is exactly as manual as one typed from
                    // the library later, and both need to retire `isTitleAutomatic` so
                    // the auto-title pass at the end of the recording doesn't overwrite it.
                    TextField("Meeting name", text: Binding(get: { meeting.title }, set: { meeting.rename(to: $0) }))
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.semibold))
                        .onSubmit { try? context.save() }
                    // Same badge style as the library row (MeetingListView) — small
                    // affordance only, not a forked layout. It's the one visual cue
                    // that the scratchpad matters less for this recording.
                    if meeting.kind == .directive {
                        Text("Directive")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.tint.opacity(0.15), in: .capsule)
                    }
                    // Set the roster while you can see who's in the room — the automatic
                    // pass at the end of the recording uses it, so getting it right now
                    // saves a re-identify later.
                    ParticipantRosterMenu(meeting: meeting)
                    if let startedAt = session.startedAt {
                        Text(startedAt, style: .timer)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
            }

            recordingPanes
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await session.stop(context: context) }
                } label: {
                    Label(
                        session.state == .finishing ? "Finishing…" : "Stop",
                        systemImage: "stop.circle.fill"
                    )
                }
                .disabled(session.state == .finishing)
            }
        }
    }

    @ViewBuilder private var recordingPanes: some View {
        @Bindable var session = session

        // Notes on top and larger: typing is the job during a meeting, and the
        // transcript is reference material you glance at.
        VSplitView {
            TextEditor(text: $session.roughNotes)
                .font(.body)
                .padding(8)
                .frame(minHeight: 260, idealHeight: 460)
                .overlay(alignment: .topLeading) {
                    if session.roughNotes.isEmpty {
                        Text("Rough notes — jot anything; AI merges it with the transcript later.")
                            .foregroundStyle(.tertiary)
                            .padding(12)
                            .allowsHitTesting(false)
                    }
                }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                    Text("Live transcript")
                    Spacer()
                    Text("\(session.liveLines.count) lines")
                        .foregroundStyle(.tertiary)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(session.liveLines.enumerated()), id: \.offset) { _, line in
                                transcriptLine(line)
                            }
                            if let volatile = session.volatileLine {
                                transcriptLine(volatile).opacity(0.5).id("volatile")
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                    }
                    .onChange(of: session.liveLines.count) {
                        proxy.scrollTo("volatile", anchor: .bottom)
                    }
                }
            }
            .frame(minHeight: 120, idealHeight: 180)
        }
    }

    private func transcriptLine(_ line: TranscriptionUpdate) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(line.channel == .me ? "Me" : "Them")
                .font(.caption.bold())
                .foregroundStyle(line.channel == .me ? .blue : .secondary)
                .frame(width: 44, alignment: .trailing)
            Text(line.text)
                .textSelection(.enabled)
        }
    }
}
