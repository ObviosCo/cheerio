import CheerioKit
import SwiftUI

/// Live view during a meeting: transcript on the left, rough-notes
/// scratchpad on the right (the Granola pattern).
struct RecordingView: View {
    @Environment(CaptureSession.self) private var session
    @Environment(\.modelContext) private var context

    var body: some View {
        @Bindable var session = session

        HSplitView {
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
                    .padding()
                }
                .onChange(of: session.liveLines.count) {
                    proxy.scrollTo("volatile", anchor: .bottom)
                }
            }
            .frame(minWidth: 300)

            TextEditor(text: $session.roughNotes)
                .font(.body)
                .padding(8)
                .frame(minWidth: 250)
                .overlay(alignment: .topLeading) {
                    if session.roughNotes.isEmpty {
                        Text("Rough notes — jot anything; AI merges it with the transcript later.")
                            .foregroundStyle(.tertiary)
                            .padding(12)
                            .allowsHitTesting(false)
                    }
                }
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
        .navigationTitle(session.meeting?.title ?? "Recording")
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
