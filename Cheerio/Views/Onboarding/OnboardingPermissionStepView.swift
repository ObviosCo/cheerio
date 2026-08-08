import CheerioKit
import SwiftUI

/// One "explain, then request" screen — shared by all three permissions the
/// walkthrough asks for, so mic/system-audio/calendar stay one implementation
/// instead of three copies that drift. Explaining before requesting means the
/// system prompt lands as something the user was told to expect rather than a
/// surprise, and every branch below leaves the "Continue" button live — a denial
/// here is a fact to note, not a wall.
struct OnboardingPermissionStepView: View {
    enum Kind: CaseIterable, Equatable {
        case microphone
        case systemAudio
        case calendar

        var symbol: String {
            switch self {
            case .microphone: "mic.fill"
            case .systemAudio: "speaker.wave.2.fill"
            case .calendar: "calendar"
            }
        }

        var title: String {
            switch self {
            case .microphone: "Hear your side of the conversation"
            case .systemAudio: "Hear everyone else's side, too"
            case .calendar: "Match meetings to your calendar"
            }
        }

        var explanation: String {
            switch self {
            case .microphone:
                "Cheerio records your microphone so it can transcribe what you say. It's processed on this Mac and never uploaded anywhere."
            case .systemAudio:
                "To capture the other side of a Zoom, Meet, or Teams call, Cheerio needs macOS's permission to record system audio — what System Settings calls \"Screen & System Audio Recording,\" even though Cheerio only ever touches audio."
            case .calendar:
                "Cheerio can read today's events to suggest recording when a meeting starts and title recordings for you. Entirely optional — skip it and Cheerio still works, you'll just be naming meetings yourself."
            }
        }

        var isOptional: Bool { self == .calendar }

        var buttonLabel: String {
            switch self {
            case .microphone: "Enable Microphone Access"
            case .systemAudio: "Enable System Audio Access"
            case .calendar: "Enable Calendar Access"
            }
        }
    }

    enum Status: Equatable {
        case notRequested
        case requesting
        case granted
        case denied
        /// System audio has no status API — see `requestSystemAudio()`.
        case requested
    }

    let kind: Kind
    var onAdvance: () -> Void

    @State private var status: Status = .notRequested

    var body: some View {
        OnboardingScaffold(
            symbol: kind.symbol,
            title: kind.title,
            subtitle: kind.explanation
        ) {
            VStack(spacing: 14) {
                if kind.isOptional {
                    Label("Optional — skip any time", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                statusView
            }
        } footer: {
            OnboardingNavBar(primaryLabel: primaryLabel, onPrimary: onAdvance)
        }
    }

    @ViewBuilder private var statusView: some View {
        switch status {
        case .notRequested, .requesting:
            Button(kind.buttonLabel) { Task { await request() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(status == .requesting)
        case .granted:
            Label("Access granted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .denied:
            VStack(spacing: 4) {
                Label("Access denied", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("You can turn this on later in System Settings → Privacy & Security.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .requested:
            Text(
                "If macOS asked for permission, you're set. Check System Settings → Privacy & Security → Screen & System Audio Recording any time you're unsure."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
        }
    }

    private var primaryLabel: String {
        status == .notRequested ? "Skip for now" : "Continue"
    }

    private func request() async {
        status = .requesting
        switch kind {
        case .microphone:
            let granted = await MicrophoneCapture.permission() == .granted
            status = granted ? .granted : .denied
        case .calendar:
            let granted = await CalendarService.shared.requestAccess()
            status = granted ? .granted : .denied
        case .systemAudio:
            await requestSystemAudio()
        }
    }

    /// There's no API to read system-audio TCC status directly: unlike the
    /// microphone, `AudioHardwareCreateProcessTap` reports `noErr` whether or not
    /// access was granted — a denial just means the tap silently delivers zeroes
    /// forever (see `SystemAudioTap` and ARCHITECTURE.md's App Sandbox gotcha,
    /// which is the same failure mode from a different cause). Claiming a
    /// granted/denied verdict here would be a guess dressed up as a fact.
    ///
    /// So instead of guessing, this runs the exact production code path — start a
    /// real tap, hold it open briefly, stop it — which is what actually triggers
    /// the one-time system prompt on a fresh install. `SystemAudioTap.stop()`
    /// still logs the SilenceWatch verdict at `.notice`/`.error`, so the outcome is
    /// verifiable in `log show` even though this screen can't surface it directly.
    private func requestSystemAudio() async {
        let tap = SystemAudioTap { _ in }
        // Tap creation failing outright is rare and unrelated to TCC (see
        // `SystemAudioTap.TapError`) — `try?` means it's not worth dead-ending the
        // walkthrough over either way.
        if (try? tap.start()) != nil {
            try? await Task.sleep(for: .seconds(1))
            tap.stop()
        }
        status = .requested
    }
}
