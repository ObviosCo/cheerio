import SwiftUI

/// The bottom bar every onboarding screen ends on. There is deliberately only one
/// forward button — its label communicates whether pressing it skips or completes
/// the step, but the action is always "move on," which is what makes every step
/// skippable without a separate skip control to keep in sync.
struct OnboardingNavBar: View {
    var showBack = false
    var onBack: () -> Void = {}
    var primaryLabel: String
    var onPrimary: () -> Void

    var body: some View {
        HStack {
            if showBack {
                Button("Back", action: onBack)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(primaryLabel, action: onPrimary)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
    }
}
