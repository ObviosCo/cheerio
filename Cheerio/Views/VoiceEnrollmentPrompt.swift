import SwiftUI

/// The confront-at-launch nudge issue #125 asks for: without an enrolled voice
/// there's little point to the app, so this shows wherever the empty state would
/// otherwise let that go unmentioned — at the top of the dashboard when nothing is
/// selected, and as a slim banner above a selected meeting's transcript
/// (``ContentView/detail``). Both placements share this one view rather than two
/// copies of the same icon/line/button arrangement.
///
/// Dismissible for the session only: `isDismissed` is a plain value the caller owns
/// in `@State`, not `@AppStorage` — the prompt has to come back on every launch for
/// as long as `EnrolledSpeaker` is empty (issue #125's own wording), which a
/// persisted dismissal would defeat the first time anyone dismissed it. What
/// actually retires it for good is `enrolledSpeakers` no longer being empty, which
/// the caller checks before ever constructing this view.
struct VoiceEnrollmentPrompt: View {
    var isDismissed: Bool
    var onDismiss: () -> Void
    var onSaved: () -> Void = {}

    @State private var showSheet = false

    var body: some View {
        if !isDismissed {
            HStack(alignment: .top, spacing: Theme.Space.x3) {
                Image(systemName: "person.wave.2")
                    .foregroundStyle(Theme.Colors.accent)
                VStack(alignment: .leading, spacing: Theme.Space.x1) {
                    Text("Cheerio can’t name anyone until it’s heard you. Thirty seconds fixes that.")
                        .chText(.notesBody)
                    Button("Enroll your voice") { showSheet = true }
                        .buttonStyle(.borderless)
                }
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Label("Dismiss", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.Colors.textSecondary)
            }
            .padding(Theme.Space.x4)
            .background(Theme.Colors.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
            .sheet(isPresented: $showSheet) {
                VoiceEnrollmentSheet(onSaved: onSaved)
            }
        }
    }
}
