import SwiftUI

/// The walkthrough's last screen. Ends on starting a recording, not a settings
/// tour — getting to a first meeting fast is the point.
struct OnboardingFinishStepView: View {
    var onBack: () -> Void
    var onFinish: () -> Void

    var body: some View {
        OnboardingScaffold(
            symbol: "flag.checkered",
            title: "You're all set",
            subtitle:
                "Cheerio lives in the menu bar from here on — click the waveform icon any time to start or stop. Let's put it to work."
        ) {
            EmptyView()
        } footer: {
            OnboardingNavBar(showBack: true, onBack: onBack, primaryLabel: "Start your first meeting", onPrimary: onFinish)
        }
    }
}
