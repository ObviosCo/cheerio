import SwiftUI

public extension Theme {

    /// The app's type roles, mapped to SwiftUI's semantic styles.
    ///
    /// SF only — no font files ship in the bundle. Apple's licence covers using
    /// the system font, not redistributing it, and the website's Literata /
    /// IBM Plex pairing is the website's alone.
    ///
    /// Every role stays on a semantic style so Dynamic Type keeps working.
    /// Never pin a point size.
    enum TextRole {
        /// A meeting's name in the library row. Sits *below* the list's section
        /// headers in visual priority — a row is one of many under a header, not a
        /// heading itself — so this stays off `.headline`'s bold weight on purpose.
        case meetingTitle
        /// The library row's second line: participant names when the meeting has
        /// any, nothing otherwise. Never the time — the row's section header
        /// already carries the day.
        case meetingSubtitle
        case sectionHeading
        case notesBody
        /// The densest reading surface in the app.
        case transcriptLine
        /// Monospaced digits so `Speaker 2` and `Speaker 3` stop shifting the rail.
        case speakerLabel
        /// Monospaced digits so the timer never reflows as it counts.
        case elapsedTimer
        case caption
    }
}

public extension View {
    func chText(_ role: Theme.TextRole) -> some View {
        modifier(CheerioTextRole(role: role))
    }
}

private struct CheerioTextRole: ViewModifier {
    let role: Theme.TextRole

    func body(content: Content) -> some View {
        switch role {
        case .meetingTitle:
            content.font(.callout).fontWeight(.medium)
                .foregroundStyle(Theme.Colors.textPrimary)
        case .meetingSubtitle:
            content.font(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
        case .sectionHeading:
            content.font(.headline)
                .foregroundStyle(Theme.Colors.textPrimary)
        case .notesBody:
            content.font(.body)
                .foregroundStyle(Theme.Colors.textPrimary)
        case .transcriptLine:
            content.font(.callout)
                .foregroundStyle(Theme.Colors.textPrimary)
                .textSelection(.enabled)
        case .speakerLabel:
            content.font(.caption).fontWeight(.semibold).monospacedDigit()
        case .elapsedTimer:
            content.font(.body).monospacedDigit()
        case .caption:
            content.font(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
    }
}
