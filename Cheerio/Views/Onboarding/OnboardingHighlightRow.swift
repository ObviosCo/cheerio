import SwiftUI

/// One line of a feature-highlight list: icon, then a sentence. Shared by the
/// welcome and teammate-voices steps, which are both "here's what you get" screens.
struct OnboardingHighlightRow: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 20)
            Text(text)
                .font(.callout)
        }
    }
}
