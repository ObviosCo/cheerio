import SwiftUI

public extension Theme {

    /// Every colour the app is allowed to use.
    ///
    /// Names match the Color Sets in `Assets.xcassets` one-for-one; the asset
    /// folders provide namespaces, so the catalog name is the full path.
    /// Light and dark variants are resolved by the catalog — never branch on
    /// `colorScheme` to pick a colour.
    enum Colors {

        // MARK: Surfaces
        // Prefer SwiftUI's own materials for the sidebar, popovers and the
        // MenuBarExtra panel. These are for content surfaces AppKit doesn't vend.

        public static let surfacePage = Color("Surface/Page", bundle: .main)
        public static let surfaceRaised = Color("Surface/Raised", bundle: .main)
        public static let surfaceSunken = Color("Surface/Sunken", bundle: .main)

        // MARK: Text

        public static let textPrimary = Color("Text/Primary", bundle: .main)
        public static let textSecondary = Color("Text/Secondary", bundle: .main)
        /// Below AA on the light page. Non-essential text only — decorative
        /// timestamps, disabled affordances. Never a label a user must read.
        public static let textTertiary = Color("Text/Tertiary", bundle: .main)
        public static let textOnAccent = Color("Text/OnAccent", bundle: .main)

        // MARK: Borders

        public static let borderSubtle = Color("Border/Subtle", bundle: .main)
        public static let borderDefault = Color("Border/Default", bundle: .main)
        public static let borderStrong = Color("Border/Strong", bundle: .main)

        // MARK: Brand
        // Appearance-invariant — the icon is the same object in both modes.
        // Copper700 is 3.98:1 on the light page: decorative use only. Where
        // copper has to carry text or a control, use `accent`.

        public static let navy900 = Color("Brand/Navy900", bundle: .main)
        public static let navy700 = Color("Brand/Navy700", bundle: .main)
        public static let navy500 = Color("Brand/Navy500", bundle: .main)
        public static let copper700 = Color("Brand/Copper700", bundle: .main)
        public static let copper500 = Color("Brand/Copper500", bundle: .main)
        public static let copper300 = Color("Brand/Copper300", bundle: .main)

        // MARK: Accent

        public static let accent = Color("Accent/Default", bundle: .main)
        public static let accentHover = Color("Accent/Hover", bundle: .main)
        /// Fill only — never text.
        public static let accentQuiet = Color("Accent/Quiet", bundle: .main)
        /// Fill only — the selected list row in a key window. Deliberately not
        /// `accent`: that copper is darkened to clear AA *as text*, which is the
        /// wrong direction for a fill sitting behind text — `textSecondary` on it
        /// reads 1.06:1. This one is tuned the other way, to hold ≥ 4.5:1 under
        /// `textPrimary` and `textSecondary` in both appearances; the numbers
        /// live in `docs/token-map.md`. Reach it through `chListRowSelection`.
        public static let accentSelection = Color("Accent/Selection", bundle: .main)
        /// `accentSelection` for a window that isn't key: neutral, the way
        /// AppKit's unemphasized selection goes grey, so a background window
        /// stops claiming attention. Same AA pairing as `accentSelection`.
        public static let accentSelectionInactive = Color("Accent/SelectionInactive", bundle: .main)

        // MARK: Semantic states
        // Never the only signal. Reach for `StatusLabel`, which pairs each of
        // these with its SF Symbol and a text label by construction.

        public static let success = Color("State/Success", bundle: .main)
        public static let attention = Color("State/Attention", bundle: .main)
        public static let error = Color("State/Error", bundle: .main)
        public static let info = Color("State/Info", bundle: .main)

        // MARK: Recording
        // Copper, not red — that keeps red meaning one thing, failure.

        public static let recording = Color("Recording/Active", bundle: .main)
        public static let recordingQuiet = Color("Recording/Quiet", bundle: .main)

        // MARK: Speaker identity
        // Fills the monogram chip and nothing else. Never transcript text,
        // never a row background. Reach these through `SpeakerSlot.color`.

        public static let speakerOnChip = Color("Speaker/OnChip", bundle: .main)
    }
}
