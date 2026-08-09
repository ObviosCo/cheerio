import SwiftUI

/// A semantic state that can't be rendered as colour alone.
///
/// The palette is CVD-safe (Wong), and there is deliberately no red/green
/// pairing — but colour is still only ever the third signal. Every case here
/// carries an SF Symbol and a text label, and the initialiser won't let you
/// drop either.
public struct StatusLabel: View {
    public enum Kind {
        case success, attention, error, info

        var color: Color {
            switch self {
            case .success: return Theme.Colors.success
            case .attention: return Theme.Colors.attention
            case .error: return Theme.Colors.error
            case .info: return Theme.Colors.info
            }
        }

        var symbol: String {
            switch self {
            case .success: return "checkmark.circle"
            case .attention: return "exclamationmark.triangle"
            case .error: return "xmark.circle"
            case .info: return "info.circle"
            }
        }
    }

    private let kind: Kind
    private let text: String

    public init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }

    public var body: some View {
        Label {
            Text(text).font(.caption)
        } icon: {
            Image(systemName: kind.symbol)
                .imageScale(.small)
        }
        .foregroundStyle(kind.color)
        .labelStyle(.titleAndIcon)
    }
}

// `.attention` replaces the ad-hoc `.orange` in three places: a voice sample
// under 30 s, a duplicate enrolled name, and a roster over the four-speaker cap.
// Amber #946000 is AA on the light page where `.orange` was not.
