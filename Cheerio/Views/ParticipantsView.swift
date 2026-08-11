import CheerioKit
import SwiftData
import SwiftUI

/// Manages the roster of known voices, so diarization returns names instead of
/// "Speaker 1".
struct ParticipantsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \EnrolledSpeaker.enrolledAt) private var speakers: [EnrolledSpeaker]

    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                if speakers.isEmpty {
                    Text("No one enrolled yet. Without a voice sample, speakers appear as “Speaker 1”, “Speaker 2”, and so on.")
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                ForEach(speakers, id: \EnrolledSpeaker.persistentModelID) { speaker in
                    row(for: speaker)
                }
            } header: {
                Text("Enrolled voices")
            } footer: {
                Text(
                    "Save as many voices as you like. At most \(SpeakerAttributionService.maximumSpeakers) are primed for any one meeting, chosen per meeting under “Who was here” — so a voice that wasn't in the room doesn't take a slot from someone who was."
                )
                .font(.caption)
                // Explicit, not left to the Form's own footer style: the system's
                // grouped-form footer gray measures 3.9:1 in light mode, under AA
                // (found by the #142 contrast audit).
                .foregroundStyle(Theme.Colors.textSecondary)
            }

            Section("Add a voice") {
                VoiceEnrollmentRecorder()
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 420)
        .alert("Couldn't update the roster", isPresented: $errorMessage.presented()) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder private func row(for speaker: EnrolledSpeaker) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(speaker.name)
                    if speaker.isMe {
                        Text("me")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.tint.opacity(0.15), in: .capsule)
                    }
                }
                Text(durationLabel(for: speaker))
                    .font(.caption)
                    .foregroundStyle(
                        speaker.hasEnoughAudio
                            ? AnyShapeStyle(Theme.Colors.textSecondary) : AnyShapeStyle(Theme.Colors.attention)
                    )
            }
            Spacer()
            // You're in every meeting you record, so this voice is pre-selected and is
            // the last one the speaker cap drops.
            Button(speaker.isMe ? "Not me" : "This is me") { setMe(speaker, isMe: !speaker.isMe) }
                .buttonStyle(.borderless)
            Button("Remove", role: .destructive) { remove(speaker) }
                .buttonStyle(.borderless)
        }
    }

    /// Only one voice can be you, so claiming it clears whoever held it before.
    private func setMe(_ speaker: EnrolledSpeaker, isMe: Bool) {
        // Snapshot exactly what this call is about to flip, so a failed save can
        // restore precisely that — not everything in the context.
        let previousIsMe = speaker.isMe
        let previouslyOtherMe = speakers.filter {
            $0.persistentModelID != speaker.persistentModelID && $0.isMe
        }
        for other in speakers where other.persistentModelID != speaker.persistentModelID {
            other.isMe = false
        }
        speaker.isMe = isMe
        // Changing who "me" is changes who owns every meeting's action items, not
        // just one meeting's — re-check them all before committing (libraries are
        // dozens of meetings, and reconciliation is a cheap in-memory pass).
        let ownerNames = SpeakerLabeling.ownerNames(context: context)
        let meetings = (try? context.fetch(FetchDescriptor<Meeting>())) ?? []
        for meeting in meetings where !meeting.actionItems.isEmpty {
            meeting.reconcileActionItems(ownerNames: ownerNames)
        }
        do {
            try context.save()
        } catch {
            // This context is shared with the rest of the scene, and Settings can be
            // open while a meeting is recording: CaptureSession leaves the live
            // meeting's transcript segments unsaved in this same context until stop.
            // `context.rollback()` discards every pending change in the context, not
            // just this method's — it would throw away part of the meeting in progress
            // along with this failed toggle. Undo only what this method touched
            // instead: restore `isMe` on exactly the speakers it flipped.
            speaker.isMe = previousIsMe
            for other in previouslyOtherMe { other.isMe = true }
            errorMessage = error.localizedDescription
        }
    }

    private func durationLabel(for speaker: EnrolledSpeaker) -> String {
        let seconds = Int(speaker.duration.rounded())
        return speaker.hasEnoughAudio
            ? "\(seconds)s sample"
            : "\(seconds)s sample — shorter than recommended"
    }

    private func remove(_ speaker: EnrolledSpeaker) {
        let audioPath = speaker.audioPath
        let wasOwner = speaker.isMe
        context.delete(speaker)
        // Deleting the "me" enrollment changes who the owner is just as surely as
        // flipping the flag does — every meeting's persisted items need the same
        // re-check setMe runs, inside the same save.
        if wasOwner {
            let ownerNames = SpeakerLabeling.ownerNames(context: context)
            let meetings = (try? context.fetch(FetchDescriptor<Meeting>())) ?? []
            for meeting in meetings where !meeting.actionItems.isEmpty {
                meeting.reconcileActionItems(ownerNames: ownerNames)
            }
        }
        do {
            // Persist the deletion *before* touching the file. The other order meant a
            // failed save resurrected the enrollment on next launch pointing at audio
            // that was already gone — and every diarization pass would then skip it,
            // silently, forever.
            try context.save()
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
            return
        }
        try? AudioStorage.removeFile(atRelativePath: audioPath)
    }
}
