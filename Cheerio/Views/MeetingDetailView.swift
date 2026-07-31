import CheerioKit
import SwiftUI

struct MeetingDetailView: View {
    let meeting: Meeting

    @Environment(\.modelContext) private var context
    @State private var isRelabeling = false
    @State private var relabelError: String?
    /// Expanded by default: opening an old meeting is usually about re-reading what
    /// was said, and a collapsed disclosure made the transcript look like it was gone.
    @State private var isTranscriptExpanded = true

    private var sortedSegments: [TranscriptSegment] {
        meeting.segments.sorted { $0.startTime < $1.startTime }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                notes

                if !meeting.roughNotes.isEmpty {
                    GroupBox("Your rough notes") {
                        Text(meeting.roughNotes)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }

                if meeting.audioDirectory != nil {
                    HStack(spacing: 8) {
                        Button {
                            Task { await relabel() }
                        } label: {
                            Label(
                                isRelabeling ? "Identifying speakers…" : "Re-identify speakers",
                                systemImage: "person.wave.2"
                            )
                        }
                        .disabled(isRelabeling)
                        Text("Uses the voices enrolled in Settings → Participants.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()
                transcript
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(meeting.title)
        .alert("Couldn't identify speakers", isPresented: $relabelError.presented()) {
            Button("OK") { relabelError = nil }
        } message: {
            Text(relabelError ?? "")
        }
        .toolbar {
            ToolbarItem {
                ShareLink(item: exportMarkdown()) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    /// The window title bar carries the meeting name, but the detail column needs its
    /// own heading — and the date is how you tell two "Call with Mary" apart.
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(meeting.title)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        var parts = [meeting.startedAt.formatted(date: .abbreviated, time: .shortened)]
        if let endedAt = meeting.endedAt {
            let elapsed = Int(endedAt.timeIntervalSince(meeting.startedAt).rounded())
            parts.append(
                Duration.seconds(elapsed).formatted(
                    .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)
                )
            )
        } else {
            // No end date means the app quit mid-recording; say so rather than
            // showing a duration of zero.
            parts.append("didn’t finish recording")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var notes: some View {
        if let notes = meeting.enhancedNotes, !notes.isEmpty {
            MarkdownNotesView(markdown: notes)
        } else {
            // Summarization can fail, or never have run. The transcript below is
            // still the record, so point at it.
            Label(
                "No enhanced notes for this meeting — the transcript below is intact.",
                systemImage: "sparkles"
            )
            .foregroundStyle(.secondary)
        }
    }

    private var transcript: some View {
        DisclosureGroup(isExpanded: $isTranscriptExpanded) {
            if sortedSegments.isEmpty {
                Text("No transcript for this meeting.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(sortedSegments) { segment in
                        HStack(alignment: .top, spacing: 8) {
                            Text(segment.displayLabel)
                                .font(.caption.bold())
                                .foregroundStyle(segment.channel == .me ? .blue : .secondary)
                                .frame(width: 72, alignment: .trailing)
                            Text(segment.text)
                                .font(.callout)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.top, 6)
            }
        } label: {
            Text("Transcript (\(meeting.segments.count) segments)")
                .font(.headline)
        }
    }

    /// Re-runs diarization. Worth offering because labels improve as more voices get
    /// enrolled, and the audio stays on disk until retention purges it.
    private func relabel() async {
        isRelabeling = true
        defer { isRelabeling = false }
        do {
            try await SpeakerLabeling.label(meeting: meeting, context: context)
        } catch {
            relabelError = error.localizedDescription
        }
    }

    private func exportMarkdown() -> String {
        var out = "# \(meeting.title)\n\(meeting.startedAt.formatted())\n\n"
        if let notes = meeting.enhancedNotes { out += notes + "\n\n" }
        out += "## Transcript\n\(meeting.transcriptText)\n"
        return out
    }
}
