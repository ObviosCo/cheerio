import CheerioKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            PrivacySettingsView()
                .tabItem { Label("Privacy", systemImage: "lock") }
            ParticipantsView()
                .tabItem { Label("Participants", systemImage: "person.2") }
            UpdateSettingsView()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
    }
}

struct UpdateSettingsView: View {
    /// Both toggles read and write Sparkle's own user defaults through the updater.
    /// There is no `@AppStorage` here on purpose: a second copy of these switches would
    /// drift from the ones Sparkle actually consults.
    @Environment(AppUpdater.self) private var updater

    var body: some View {
        // `@Environment` has no projected value, so the bindings the toggles need come
        // from re-wrapping the same object with `@Bindable`. Still one source of truth.
        @Bindable var updater = updater

        Form {
            Section {
                Toggle("Automatically check for updates", isOn: $updater.checksAutomatically)
                Toggle("Automatically download and install them", isOn: $updater.downloadsAutomatically)
                    // Nothing to install if nothing ever looks.
                    .disabled(!updater.checksAutomatically)
                Text(
                    """
                    Checking for updates is the only thing Cheerio uses the network for. It asks the \
                    release feed whether there is a newer version, and downloads it if you say so. \
                    Nothing is sent about you or your Mac.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } header: {
                Text("Updates")
            }

            Section {
                Button("Check for Updates Now") { updater.checkForUpdates() }
                Text(
                    "Recording, transcribing and summarizing never touch the network, and no scheduled check runs while a recording is going."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
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
