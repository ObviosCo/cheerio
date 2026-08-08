import SwiftUI

/// Feature discovery, not a second enrollment: teaches that other people can be
/// enrolled too, and that importing a voice a teammate already shared is coming
/// (issue #16) but isn't built yet — so this only teaches enrolling a second
/// speaker by hand, same as you just did for yourself.
struct OnboardingTeammateVoicesStepView: View {
    var onBack: () -> Void
    var onAdvance: () -> Void

    var body: some View {
        OnboardingScaffold(
            symbol: "person.2.wave.2.fill",
            title: "Recognize everyone, not just you",
            subtitle:
                "Your voice is enrolled. Anyone you meet with often is worth naming too, so their turns show up with their name instead of “Speaker 2”."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                OnboardingHighlightRow(
                    symbol: "person.badge.plus",
                    text:
                        "Enroll a teammate any time from Settings → Participants — the same 30-second recording you just did for yourself."
                )
                OnboardingHighlightRow(
                    symbol: "square.and.arrow.down.on.square",
                    text:
                        "Importing a voice a teammate already shared with you is coming soon, so you won't have to re-record people who use Cheerio too."
                )
            }
            .frame(maxWidth: 400, alignment: .leading)
        } footer: {
            OnboardingNavBar(showBack: true, onBack: onBack, primaryLabel: "Continue", onPrimary: onAdvance)
        }
    }
}
