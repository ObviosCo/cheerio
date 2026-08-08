import CheerioKit
import SwiftData
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            PrivacySettingsView()
                .tabItem { Label("Privacy", systemImage: "lock") }
            ParticipantsView()
                .tabItem { Label("Participants", systemImage: "person.2") }
            TranscriptCallbackSettingsView()
                .tabItem { Label("Callback", systemImage: "terminal") }
        }
    }
}

struct PrivacySettingsView: View {
    @Environment(\.modelContext) private var context
    @AppStorage(AudioRetention.defaultsKey) private var retentionDays = AudioRetention.default.rawValue

    private var retention: AudioRetention {
        AudioRetention(rawValue: retentionDays) ?? .default
    }

    var body: some View {
        Form {
            Section {
                Picker("Keep recorded audio", selection: $retentionDays) {
                    ForEach(AudioRetention.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Privacy")
            }

            Section {
                Button("Delete audio now") {
                    // .none purges everything that has finished recording.
                    _ = try? AudioRetentionService.purge(retention: .none, context: context)
                }
                Text("Transcripts and notes are always kept. Nothing ever leaves this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onChange(of: retentionDays) {
            // Shrinking the window should take effect right away, not next launch.
            _ = try? AudioRetentionService.purge(retention: retention, context: context)
        }
    }

    private var explanation: String {
        switch retention {
        case .none:
            "Audio is deleted as soon as a meeting finishes transcribing."
        case .forever:
            "Audio is kept until you delete it yourself."
        case .day, .week, .month:
            "Audio is deleted \(retention.label) after a meeting ends."
        }
    }
}

/// Configures the transcript-ready callback (issue #26): a command that runs
/// once a meeting is fully processed, so local agentic tooling can pick up the
/// transcript without anyone copy-pasting it. Off by default — an empty command
/// disables it, per ``TranscriptCallbackSettings``.
struct TranscriptCallbackSettingsView: View {
    @Environment(\.modelContext) private var context
    @AppStorage(TranscriptCallbackSettings.commandDefaultsKey) private var command = ""
    @AppStorage(TranscriptCallbackScope.defaultsKey) private var scopeRaw = TranscriptCallbackScope.default.rawValue

    /// Most recently completed meeting, for the "run now" test button — the same
    /// `endedAt != nil` test `AudioRetentionService` uses for "finished meetings".
    @Query(
        filter: #Predicate<Meeting> { $0.endedAt != nil },
        sort: \Meeting.endedAt,
        order: .reverse
    )
    private var completedMeetings: [Meeting]

    /// Read directly from the singleton rather than copied into `@State`: it's
    /// already `@Observable`, and accessing `status.outcome` from `body` is what
    /// registers this view for updates when `TranscriptReadyRunner` changes it.
    private let status = TranscriptCallbackStatus.shared

    private var trimmedCommand: String {
        command.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var lastMeeting: Meeting? { completedMeetings.first }

    var body: some View {
        Form {
            Section {
                TextField("Command", text: $command, prompt: Text("e.g. claude -p \"Handle this transcript\""))
                    .font(.system(.body, design: .monospaced))
                Picker("Run for", selection: $scopeRaw) {
                    ForEach(TranscriptCallbackScope.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
                Text(
                    "Runs when a transcript is fully ready — recording stopped, speakers identified, notes generated. The command receives the transcript as JSON on stdin, at the path in CHEERIO_EXPORT_PATH, and gets CHEERIO_MEETING_ID, CHEERIO_MEETING_KIND, and CHEERIO_TITLE in its environment. Never anything from the transcript itself is placed on the command line. Leave blank to turn this off."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } header: {
                Text("When a transcript is ready")
            }

            Section {
                Button("Run now on last meeting") { runNow() }
                    .disabled(lastMeeting == nil || trimmedCommand.isEmpty)
                statusView
            } footer: {
                Text(
                    "Fires your command against the most recently completed meeting, regardless of the scope above, so you can verify it works without recording something new."
                )
                .font(.caption)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }

    @ViewBuilder private var statusView: some View {
        switch status.outcome {
        case .idle:
            EmptyView()
        case .running(let title):
            Label("Running for “\(title)”…", systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .succeeded(let title):
            Label("Finished for “\(title)”", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let title, let detail):
            Label("Failed for “\(title)”: \(detail)", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
    }

    private func runNow() {
        guard let lastMeeting, !trimmedCommand.isEmpty else { return }
        let ownerNames = SpeakerLabeling.ownerNames(context: context)
        TranscriptReadyRunner.fireForTest(command: trimmedCommand, export: lastMeeting.export(ownerNames: ownerNames))
    }
}
