import CheerioKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            PrivacySettingsView()
                .tabItem { Label("Privacy", systemImage: "lock") }
            ParticipantsView()
                .tabItem { Label("Participants", systemImage: "person.2") }
        }
    }
}

struct GeneralSettingsView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                Button("Show the Welcome Walkthrough Again") {
                    openWindow(id: OnboardingView.windowID)
                }
                Text(
                    "Walks through permissions and voice enrollment again. Nothing you've already set up gets reset or re-asked unless you want it to."
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
