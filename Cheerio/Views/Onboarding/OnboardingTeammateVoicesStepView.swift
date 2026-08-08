import SwiftUI

/// Feature discovery, not a second enrollment: teaches that other people can be
/// enrolled too. This screen is reached whether or not the previous step's
/// enrollment was completed or skipped, so its copy stays neutral about that —
/// and until voice import (issue #16) exists, it only teaches enrolling a second
/// speaker by hand, paired with a reminder to get their OK before recording them.
struct OnboardingTeammateVoicesStepView: View {
    var onBack: () -> Void
    var onAdvance: () -> Void

    var body: some View {
        OnboardingScaffold(
            symbol: "person.2.wave.2.fill",
            title: "Recognize everyone, not just you",
            subtitle:
                "Anyone you meet with often is worth naming too, so their turns show up with their name instead of “Speaker 2”."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                OnboardingHighlightRow(
                    symbol: "person.badge.plus",
                    text:
                        "Enroll a teammate any time from Settings → Participants — a 30-second recording, the same way your own voice is enrolled."
                )
                OnboardingHighlightRow(
                    symbol: "hand.raised",
                    text:
                        "Let them know before you record their voice — the same courtesy you'd want for your own."
                )
            }
            .frame(maxWidth: 400, alignment: .leading)
        } footer: {
            OnboardingNavBar(showBack: true, onBack: onBack, primaryLabel: "Continue", onPrimary: onAdvance)
        }
    }
}
