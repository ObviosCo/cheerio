import SwiftUI

/// The "Add your voice" sheet every enrollment nudge in the app opens: the live
/// recording's banner (``RecordingView``) and the empty-state's confront-at-launch
/// prompt (``VoiceEnrollmentPrompt``, #125) both present this instead of each
/// wrapping ``VoiceEnrollmentRecorder`` in its own copy of the same header and
/// dismiss button.
struct VoiceEnrollmentSheet: View {
    /// Runs after a successful save, in addition to dismissing the sheet — so a
    /// caller can also clear whatever banner state made the button visible in the
    /// first place.
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add your voice")
                .font(.headline)
            VoiceEnrollmentRecorder(markAsMe: true) { _ in
                onSaved()
                dismiss()
            }
            Button("Done") { dismiss() }
                .buttonStyle(.bordered)
        }
        .padding(20)
        .frame(width: 380)
    }
}
