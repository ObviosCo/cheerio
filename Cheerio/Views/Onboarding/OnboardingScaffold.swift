import SwiftUI

/// Shared chrome for every onboarding screen: a big icon, a title, an explanation,
/// then whatever the step needs, then a footer nav bar. One place for this is what
/// makes seven different screens read as one flow — and what makes each of them
/// usable as-is for the website's "how it works" screenshots.
struct OnboardingScaffold<Content: View, Footer: View>: View {
    let symbol: String
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)

            Image(systemName: symbol)
                .font(.system(size: 40))
                .foregroundStyle(.tint)
                .frame(width: 84, height: 84)
                .background(.tint.opacity(0.12), in: .circle)

            VStack(spacing: 8) {
                Text(title)
                    .font(.title.weight(.semibold))
                    .multilineTextAlignment(.center)
                if let subtitle {
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 420)
                }
            }

            content

            Spacer(minLength: 0)
            footer
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
