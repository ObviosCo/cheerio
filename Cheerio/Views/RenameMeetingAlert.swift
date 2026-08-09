import CheerioKit
import SwiftData
import SwiftUI

/// The "Rename meeting" alert — a text field plus Save/Cancel, tied to whichever
/// meeting triggered it. `MeetingListView`'s row context menu and
/// `MeetingDetailView`'s pencil button both drive this one flow rather than each
/// keeping its own copy of the alert and the write it commits.
private struct RenameMeetingAlert: ViewModifier {
    @Binding var renamingMeeting: Meeting?
    @Binding var renameText: String
    let context: ModelContext

    func body(content: Content) -> some View {
        content.alert("Rename meeting", isPresented: $renamingMeeting.presented()) {
            TextField("Meeting name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingMeeting = nil }
            Button("Save") { applyRename() }
        }
    }

    private func applyRename() {
        defer { renamingMeeting = nil }
        guard let renamingMeeting else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        renamingMeeting.rename(to: trimmed)
        try? context.save()
    }
}

extension View {
    /// Attaches the shared rename alert. Callers open it by setting `renamingMeeting`
    /// (after seeding `text` with the current title) — see `MeetingListView`'s
    /// context-menu button and `MeetingDetailView`'s pencil button.
    func renameMeetingAlert(
        renamingMeeting: Binding<Meeting?>,
        text: Binding<String>,
        context: ModelContext
    ) -> some View {
        modifier(RenameMeetingAlert(renamingMeeting: renamingMeeting, renameText: text, context: context))
    }
}
