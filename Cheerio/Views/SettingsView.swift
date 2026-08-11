import CheerioKit
import SwiftData
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
            UpdateSettingsView()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
            TranscriptCallbackSettingsView()
                .tabItem { Label("Callback", systemImage: "terminal") }
            MCPSettingsView()
                .tabItem { Label("Agents", systemImage: "sparkles") }
        }
    }
}

/// Setup for the bundled MCP server (issue #28) — the pull half of "actionable", where
/// an agent asks Cheerio about a meeting rather than waiting to be handed one.
///
/// Read-only display and copy buttons, deliberately. There is no "install into Claude
/// Desktop" button: that would mean Cheerio writing another app's configuration file,
/// and ``MCPClientSetup`` explains why it doesn't.
struct MCPSettingsView: View {
    /// The helper inside *this* copy of Cheerio, so the path a user copies is the one
    /// that exists — including when they're running a build from Xcode.
    private var helperPath: String {
        MCPClientSetup.helperURL(appBundle: Bundle.main.bundleURL).path(percentEncoded: false)
    }

    var body: some View {
        Form {
            Section {
                Text(
                    "Cheerio ships a small MCP server, so agents already running on this Mac can look up what was said in a meeting. It reads your meetings and can't change them, start a recording, or run anything. It talks over a pipe to whichever client launched it — nothing is listening, and Cheerio itself sends nothing off this Mac. What the client you connect does with the results is that client\u{2019}s policy: an agent backed by a cloud model will send what it reads to that model."
                )
                .font(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
            } header: {
                Text("Let agents read your meetings")
            }

            Section {
                CopyableSnippet(label: "Server", text: helperPath, monospaced: true)
                Text("Installed inside Cheerio itself, so it updates when Cheerio does.")
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }

            Section {
                CopyableSnippet(label: "Claude Code", text: MCPClientSetup.claudeCodeCommand(helperPath: helperPath))
                CopyableSnippet(
                    label: "Claude Desktop", text: MCPClientSetup.desktopJSON(helperPath: helperPath),
                    caption: "Add to claude_desktop_config.json")
                CopyableSnippet(
                    label: "Codex", text: MCPClientSetup.codexTOML(helperPath: helperPath),
                    caption: "Add to ~/.codex/config.toml")
            } header: {
                Text("Add it to a client")
            } footer: {
                Text("Cheerio doesn't edit other apps' settings — copy the one you need and paste it in yourself.")
                    .font(.caption)
                    // Explicit, not left to the Form's own footer style: the
                    // system's grouped-form footer gray measures 3.9:1 in light
                    // mode, under AA (found by the #142 contrast audit).
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
    }
}

/// A block of config with a copy button, which is the only interaction this tab has.
private struct CopyableSnippet: View {
    let label: String
    let text: String
    var caption: String?
    var monospaced = true

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                Spacer()
                Button(copied ? "Copied" : "Copy") { copy() }
                    .controlSize(.small)
            }
            Text(text)
                .font(.system(.caption, design: monospaced ? .monospaced : .default))
                .foregroundStyle(Theme.Colors.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        // Long enough to read, short enough that the button is ready again if the paste
        // didn't land where they meant it to.
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
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
                .foregroundStyle(Theme.Colors.textSecondary)
            } header: {
                Text("Updates")
            }

            Section {
                Button("Check for Updates Now") { updater.checkForUpdates() }
                Text(
                    "Recording, transcribing and summarizing never touch the network, and no update check starts while a recording is going."
                )
                .font(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}

struct GeneralSettingsView: View {
    @Environment(\.openWindow) private var openWindow

    /// Both default on. `@AppStorage`'s default and `NotificationSettings`' fallback
    /// have to agree — see the comment on `NotificationSettings.isEnabled` for why
    /// neither side can use a plain `bool(forKey:)`.
    @AppStorage(NotificationSettings.suggestRecordingKey) private var suggestsRecording = true
    @AppStorage(NotificationSettings.notesReadyKey) private var announcesNotesReady = true

    /// Whether macOS is currently refusing to deliver anything, so the toggles can
    /// say why they appear to do nothing.
    @State private var systemDenied = false

    @AppStorage(ProcessingHoldDuration.defaultsKey) private var holdSeconds = ProcessingHoldDuration.default.rawValue

    private var holdDuration: ProcessingHoldDuration {
        ProcessingHoldDuration(rawValue: holdSeconds) ?? .default
    }

    var body: some View {
        Form {
            Section {
                Picker("Review before processing", selection: $holdSeconds) {
                    ForEach(ProcessingHoldDuration.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
                Text(holdExplanation)
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            } header: {
                Text("After a recording stops")
            }

            Section {
                Toggle("Suggest recording when a calendar meeting starts", isOn: $suggestsRecording)
                Toggle("Notify when notes are ready", isOn: $announcesNotesReady)
                Text(
                    "Cheerio asks macOS for permission to notify you the first time it has something to say — not at launch. Meeting suggestions need calendar access; without it there's nothing to suggest."
                )
                .font(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
                if systemDenied {
                    // Stated once, where somebody has come looking, and nowhere else:
                    // no badge, no banner, nothing that follows the user around. The
                    // toggles stay live because they record what you want, which is
                    // still worth recording while the system says no.
                    Text("macOS is currently blocking notifications from Cheerio. Turn them on in System Settings › Notifications.")
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            } header: {
                Text("Notifications")
            }

            Section {
                Button("Show the Welcome Walkthrough Again") {
                    openWindow(id: OnboardingView.windowID)
                }
                Text(
                    "Walks through permissions and voice enrollment again. Nothing you've already set up gets reset or re-asked unless you want it to."
                )
                .font(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .task {
            // A read, never a request: opening Settings must not be a way to trigger
            // the permission prompt out of context.
            systemDenied = await NotificationService.shared.isDeniedBySystem()
        }
    }

    /// "Processed", not "notes and the callback run" — the callback is off by
    /// default and declinable per meeting, so naming it here would promise
    /// something the default configuration never does.
    private var holdExplanation: String {
        switch holdDuration {
        case .off:
            "A stopped recording is processed the moment it ends, with no pause."
        default:
            "A stopped meeting waits \(holdDuration.label.lowercased()) — or until you confirm — before it's processed, so you can still add rough notes, set the meeting kind, and adjust whether the callback runs. Editing anything restarts the wait. Directives always process immediately."
        }
    }
}

struct PrivacySettingsView: View {
    @Environment(\.modelContext) private var context
    /// For the purge calls' exclusion set only — a purge from here can land while
    /// a held meeting's pipeline (post-meeting processing, launch recovery) is
    /// mid-diarization on the very files it would delete.
    @Environment(CaptureSession.self) private var session
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
                    .foregroundStyle(Theme.Colors.textSecondary)
            } header: {
                Text("Privacy")
            }

            Section {
                Button("Delete audio now") {
                    // .none purges everything that has finished recording — except
                    // audio a hold or an in-flight pipeline still needs, which the
                    // purge's own plan check and this exclusion set carve out; the
                    // pipeline's concluding purge picks those up.
                    _ = try? AudioRetentionService.purge(
                        retention: .none, context: context,
                        excludingMeetingIDs: session.meetingIDsBeingProcessed)
                }
                Text("Transcripts and notes are always kept. Nothing ever leaves this Mac.")
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onChange(of: retentionDays) {
            // Shrinking the window should take effect right away, not next launch.
            _ = try? AudioRetentionService.purge(
                retention: retention, context: context,
                excludingMeetingIDs: session.meetingIDsBeingProcessed)
        }
    }

    private var explanation: String {
        switch retention {
        case .none:
            "Audio is deleted as soon as a meeting finishes transcribing."
        case .forever:
            "Audio is kept until you delete it yourself."
        case .day, .threeDays, .week, .month:
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
    /// Only for the readiness check below — this tab never starts or stops
    /// anything.
    @Environment(CaptureSession.self) private var session
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

    /// Nil while a recording is in flight. `CaptureSession.stop` sets `endedAt`
    /// *before* diarization and enhancement run, so between those two moments the
    /// most recent `endedAt != nil` meeting has channel-only labels and no notes.
    /// Exporting it then would contradict the single definition of "ready" that
    /// `CaptureSession` documents at its `fireTranscriptReadyCallback` call — the
    /// test button exists to rehearse the real callback, so it has to wait for
    /// the same point.
    ///
    /// `isProcessingInBackground` for the same reason `UpdatePolicy` reads it:
    /// launch recovery of a held meeting runs that same pipeline while `state`
    /// sits at `.idle`, and the meeting it's mid-way through is exactly the
    /// "most recently completed" one this would export half-processed.
    private var lastMeeting: Meeting? {
        guard session.state == .idle, !session.isProcessingInBackground else { return nil }
        return completedMeetings.first
    }

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
                    "Runs when a meeting finishes processing — recording stopped, and speaker identification and note generation have completed or conclusively failed (the export carries whatever exists). The command receives the transcript as JSON on stdin, at the path in CHEERIO_EXPORT_PATH, and gets CHEERIO_MEETING_ID, CHEERIO_MEETING_KIND, and CHEERIO_TITLE in its environment. Never anything from the transcript itself is placed on the command line. Commands resolve against a fixed PATH — the system directories plus /opt/homebrew/bin, /opt/homebrew/sbin, /usr/local/bin, and ~/.local/bin — not your shell profile, so give an absolute path for anything installed elsewhere. Leave blank to turn this off."
                )
                .font(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
            } header: {
                Text("When a transcript is ready")
            }

            Section {
                Button("Run now on last meeting") { runNow() }
                    .disabled(lastMeeting == nil || trimmedCommand.isEmpty)
                if session.state != .idle || session.isProcessingInBackground {
                    Text("Waiting for the current recording to finish processing.")
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                statusView
            } footer: {
                Text(
                    "Fires your command against the most recently completed meeting, regardless of the scope above, so you can verify it works without recording something new."
                )
                .font(.caption)
                // Explicit, not left to the Form's own footer style: the system's
                // grouped-form footer gray measures 3.9:1 in light mode, under AA
                // (found by the #142 contrast audit).
                .foregroundStyle(Theme.Colors.textSecondary)
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
                .foregroundStyle(Theme.Colors.textSecondary)
        case .succeeded(let title):
            Label("Finished for “\(title)”", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
        case .failed(let title, let detail):
            // `.error`, not `.attention` — this is an actual failure of the command
            // run, not a warning to notice and move past.
            StatusLabel(.error, "Failed for “\(title)”: \(detail)")
                .lineLimit(2)
        }
    }

    private func runNow() {
        guard let lastMeeting, !trimmedCommand.isEmpty else { return }
        let ownerNames = SpeakerLabeling.ownerNames(context: context)
        let export = lastMeeting.export(ownerNames: ownerNames)
        // Building the export reads `stableID`, which backfills `uuid` for a meeting
        // recorded before that field existed. Persist that before the command sees
        // it as CHEERIO_MEETING_ID — an external consumer must never be handed an
        // identifier that a quit-before-autosave would replace with a different one.
        // If it can't be persisted the invocation is off: a callback with an ID that
        // may not survive a relaunch is worse than no callback. Say so on the same
        // status line the run itself would have used, rather than doing nothing while
        // the button appears to have worked.
        do {
            try context.save()
        } catch {
            status.markFailedBeforeStarting(
                title: export.title,
                detail: "Couldn't save this meeting's ID, so the command wasn't run: \(error.localizedDescription)"
            )
            return
        }
        TranscriptReadyRunner.fireForTest(command: trimmedCommand, export: export)
    }
}
