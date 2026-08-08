import SwiftUI

/// The walkthrough's opening screen: what Cheerio does, before asking for anything.
struct OnboardingWelcomeStepView: View {
    var onAdvance: () -> Void

    var body: some View {
        OnboardingScaffold(
            symbol: "waveform",
            title: "Welcome to Cheerio",
            subtitle:
                "Meeting notes that never leave this Mac. A microphone, system audio, and a voice or two — that's the whole setup, and it takes under a minute."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                OnboardingHighlightRow(symbol: "mic.fill", text: "Records both sides of the call — you and everyone else")
                OnboardingHighlightRow(symbol: "text.bubble.fill", text: "Transcribes live, entirely on-device")
                OnboardingHighlightRow(symbol: "sparkles", text: "Turns rough notes into a real summary when you're done")
            }
            .frame(maxWidth: 380, alignment: .leading)
        } footer: {
            OnboardingNavBar(primaryLabel: "Get Started", onPrimary: onAdvance)
        }
    }
}
