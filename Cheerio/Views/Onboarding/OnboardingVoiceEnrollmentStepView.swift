import SwiftUI

/// The centerpiece of the walkthrough: enrolling your own voice, marked "me", so
/// diarization returns your name instead of "Speaker 1" from the very first
/// meeting. Reuses `VoiceEnrollmentRecorder` — the same recorder Settings →
/// Participants uses — rather than a parallel implementation.
struct OnboardingVoiceEnrollmentStepView: View {
    var onBack: () -> Void
    var onAdvance: () -> Void

    @State private var didSave = false

    var body: some View {
        OnboardingScaffold(
            symbol: "person.wave.2.fill",
            title: "Put a name to your voice",
            subtitle:
                "This is what turns “Speaker 1” into your name in every transcript — the single biggest upgrade you can make before your first meeting."
        ) {
            VoiceEnrollmentRecorder(markAsMe: true) { _ in didSave = true }
                .frame(maxWidth: 380)
        } footer: {
            OnboardingNavBar(
                showBack: true,
                onBack: onBack,
                primaryLabel: didSave ? "Continue" : "Skip for now",
                onPrimary: onAdvance
            )
        }
    }
}
