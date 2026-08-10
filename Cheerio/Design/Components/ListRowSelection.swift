import SwiftUI

public extension View {
    /// Cheerio's list-row selection: a quiet copper fill the row draws itself,
    /// paired with the row's ordinary text tokens.
    ///
    /// Exists because the system treatment can't hold WCAG AA here from either
    /// side. AppKit's emphasized selection fills the row with the app accent and
    /// re-colours only *semantic* foreground styles — text pinned to a catalog
    /// colour, which is every `chText` role, keeps its page values and sits
    /// dark-on-dark over the light-mode copper. And the accent is the wrong fill
    /// anyway: `Accent/Default` is copper darkened to clear AA *as text*, so even
    /// correctly inverted white text only reaches 1.9:1 on its dark-mode value.
    /// Rather than fight both, the row supplies its own background — which
    /// replaces the system pill wholesale (verified by offscreen render on
    /// macOS 26) — using `Accent/Selection`, a fill chosen to clear 4.5:1 under
    /// `Text/Primary` and `Text/Secondary` in both appearances. When the window
    /// isn't key it falls back to the neutral `Accent/SelectionInactive`, the
    /// same way unemphasized system selections go grey.
    func chListRowSelection(isSelected: Bool) -> some View {
        modifier(CheerioListRowSelection(isSelected: isSelected))
    }
}

private struct CheerioListRowSelection: ViewModifier {
    /// `.key` and `.active` count as emphasized; `.inactive` mirrors AppKit's
    /// unemphasized-selection grey.
    @Environment(\.controlActiveState) private var controlActiveState

    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            // The row draws its own selection, so nothing inside it may render
            // the *system's* selected treatment: SwiftUI still reports increased
            // prominence for a selected row, which would flip any default-styled
            // text to white over a fill chosen for dark text in light mode.
            .environment(\.backgroundProminence, .standard)
            .listRowBackground(background)
    }

    @ViewBuilder private var background: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(
                    controlActiveState == .inactive
                        ? Theme.Colors.accentSelectionInactive : Theme.Colors.accentSelection
                )
                // The system pill this replaces doesn't run edge-to-edge either.
                .padding(.horizontal, Theme.Space.x1)
        }
    }
}
