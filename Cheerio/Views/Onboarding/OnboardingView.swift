import CheerioKit
import SwiftData
import SwiftUI

/// The first-run walkthrough: welcome, explain-then-request each permission, enroll
/// your voice, a look at enrolling teammates, then straight into a first recording.
///
/// Shown automatically once — `ContentView` hands off to this window itself, the
/// moment its own `.task` runs, for as long as ``OnboardingState/hasCompleted`` is
/// false (see #63: `.defaultLaunchBehavior` alone doesn't reliably keep the main
/// window from claiming launch instead on macOS 26) — and re-openable afterward from
/// Settings and the Help menu. Recording is never gated on any of this — every
/// screen can be skipped, and `CaptureSession.start` doesn't know this window exists.
struct OnboardingView: View {
    static let windowID = "onboarding"

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(CaptureSession.self) private var session
    @Environment(\.modelContext) private var context

    @State private var coordinator = OnboardingCoordinator()

    var body: some View {
        VStack(spacing: 0) {
            OnboardingProgressDots(step: coordinator.step)

            Group {
                switch coordinator.step {
                case .welcome:
                    OnboardingWelcomeStepView(onAdvance: coordinator.advance)
                case .microphone:
                    OnboardingPermissionStepView(kind: .microphone, onAdvance: coordinator.advance)
                case .systemAudio:
                    OnboardingPermissionStepView(kind: .systemAudio, onAdvance: coordinator.advance)
                case .calendar:
                    OnboardingPermissionStepView(kind: .calendar, onAdvance: coordinator.advance)
                case .voiceEnrollment:
                    OnboardingVoiceEnrollmentStepView(onBack: coordinator.back, onAdvance: coordinator.advance)
                case .teammateVoices:
                    OnboardingTeammateVoicesStepView(onBack: coordinator.back, onAdvance: coordinator.advance)
                case .finish:
                    OnboardingFinishStepView(onBack: coordinator.back, onFinish: startFirstMeeting)
                }
            }
        }
        .frame(width: 560, height: 600)
        .onDisappear {
            // Every way this window closes — finishing, skipping every step, or just
            // hitting the close button — means "don't show this automatically again."
            // It stays reachable from Settings/Help regardless.
            OnboardingState.hasCompleted = true
            openWindow(id: MenuBarView.mainWindowID)
        }
    }

    /// Mirrors the start path in `MenuBarView`/`MeetingListView`: check the
    /// permission that has a real status to check, then let `CaptureSession`
    /// report anything else that goes wrong. `startFailure` surfaces in the main
    /// window's alerts once `onDisappear` opens it.
    private func startFirstMeeting() {
        Task {
            guard await MicrophoneCapture.permission() == .granted else {
                session.startFailure = .microphoneDenied
                dismiss()
                return
            }
            do {
                try await session.start(
                    title: "Meeting \(Date.now.formatted(date: .abbreviated, time: .shortened))",
                    calendarEventID: nil,
                    context: context
                )
            } catch {
                session.startFailure = .failed(error.localizedDescription)
            }
            dismiss()
        }
    }
}
