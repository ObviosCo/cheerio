import SwiftUI

/// A row of dots showing where you are in the walkthrough. Purely decorative — the
/// nav bar's buttons do the actual navigating — but it's what keeps a seven-step
/// flow from feeling like it might go on forever.
struct OnboardingProgressDots: View {
    let step: OnboardingCoordinator.Step

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingCoordinator.Step.allCases, id: \.self) { candidate in
                Circle()
                    .fill(candidate.rawValue <= step.rawValue ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.top, 18)
        // Decorative only — the nav bar's buttons do the actual navigating — so
        // VoiceOver should skip past a row of otherwise-unlabeled circles.
        .accessibilityHidden(true)
    }
}
