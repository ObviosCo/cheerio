import CheerioKit
import SwiftUI

struct MeetingDetailView: View {
    let meeting: Meeting

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let notes = meeting.enhancedNotes {
                    Text(LocalizedStringKey(notes))
                        .textSelection(.enabled)
                } else {
                    Text("No enhanced notes for this meeting.")
                        .foregroundStyle(.secondary)
                }

                if !meeting.roughNotes.isEmpty {
                    GroupBox("Your rough notes") {
                        Text(meeting.roughNotes)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }

                DisclosureGroup("Transcript (\(meeting.segments.count) segments)") {
                    Text(meeting.transcriptText)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .navigationTitle(meeting.title)
        .toolbar {
            ToolbarItem {
                ShareLink(item: exportMarkdown()) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    private func exportMarkdown() -> String {
        var out = "# \(meeting.title)\n\(meeting.startedAt.formatted())\n\n"
        if let notes = meeting.enhancedNotes { out += notes + "\n\n" }
        out += "## Transcript\n\(meeting.transcriptText)\n"
        return out
    }
}
