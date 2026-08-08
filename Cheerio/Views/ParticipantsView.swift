import AVFoundation
import CheerioKit
import SwiftData
import SwiftUI

/// Manages the roster of known voices, so diarization returns names instead of
/// "Speaker 1".
struct ParticipantsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \EnrolledSpeaker.enrolledAt) private var speakers: [EnrolledSpeaker]

    @State private var recorder: VoiceSampleRecorder?
    @State private var capture: MicrophoneCapture?
    @State private var pendingName = ""
    @State private var pendingPath: String?
    @State private var elapsed: TimeInterval = 0
    @State private var errorMessage: String?

    private var isRecording: Bool { recorder != nil }

    private var isSampleLongEnough: Bool { elapsed >= EnrolledSpeaker.recommendedDuration }

    private var recordingHint: String {
        guard !isSampleLongEnough else { return "Long enough — stop whenever you like." }
        let remaining = Int((EnrolledSpeaker.recommendedDuration - elapsed).rounded(.up))
        return "Keep them talking — about \(remaining)s to go."
    }

    var body: some View {
        Form {
            Section {
                if speakers.isEmpty {
                    Text("No one enrolled yet. Without a voice sample, speakers appear as “Speaker 1”, “Speaker 2”, and so on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            }

            Section("Add a voice") {
                TextField("Name", text: $pendingName)
                    .disabled(isRecording)

                if isRecording {
                    HStack {
                        Image(systemName: "record.circle.fill").foregroundStyle(.red)
                        Text(elapsed.formatted(.number.precision(.fractionLength(0))) + "s")
                            .monospacedDigit()
                        Spacer()
                        // Naming the early exit "Save anyway" makes stopping short a
                        // choice rather than the obvious thing to do.
                        Button(isSampleLongEnough ? "Stop and save" : "Save anyway") {
                            Task { await stopRecording() }
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                    ProgressView(value: min(elapsed / EnrolledSpeaker.recommendedDuration, 1))
                    Text(recordingHint)
                        .font(.caption)
                        .foregroundStyle(isSampleLongEnough ? .green : .secondary)
                } else {
                    // Up front, not after the fact: this guidance only appeared once
                    // recording had already started, so nobody knew how long to talk.
                    Text(
                        "Have them talk naturally for about \(Int(EnrolledSpeaker.recommendedDuration)) seconds — read something aloud if it helps. Shorter samples get mistaken for similar voices, or split into two speakers mid-meeting."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Button("Record voice sample") { Task { await startRecording() } }
                        .disabled(pendingName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 420)
        .alert("Couldn't record the sample", isPresented: $errorMessage.presented()) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onDisappear {
            // Closing Settings or switching tabs mid-recording left the microphone
            // running until the view was torn down, and a partial CAF with nothing
            // referencing it.
            guard isRecording else { return }
            let recorder = recorder
            let capture = capture
            let pendingPath = pendingPath
            capture?.stop()
            Task {
                await recorder?.finish()
                if let pendingPath {
                    try? AudioStorage.removeFile(atRelativePath: pendingPath)
                }
            }
        }
        .task(id: isRecording) {
            // Poll the recorder for a live duration readout while capturing.
            while isRecording, !Task.isCancelled {
                elapsed = await recorder?.duration ?? 0
                try? await Task.sleep(for: .milliseconds(200))
            }
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
                    .foregroundStyle(speaker.hasEnoughAudio ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
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
            context.rollback()
            errorMessage = error.localizedDescription
        }
    }

    private func durationLabel(for speaker: EnrolledSpeaker) -> String {
        let seconds = Int(speaker.duration.rounded())
        return speaker.hasEnoughAudio
            ? "\(seconds)s sample"
            : "\(seconds)s sample — shorter than recommended"
    }

    private func startRecording() async {
        guard await MicrophoneCapture.permission() == .granted else {
            errorMessage = "Microphone access is required. Turn it on in System Settings → Privacy & Security → Microphone."
            return
        }
        do {
            let (relativePath, url) = try AudioStorage.makeSpeakerSampleFile()
            let recorder = VoiceSampleRecorder(destination: url)
            await recorder.start()
            let capture = MicrophoneCapture { buffer in recorder.submit(buffer) }
            try capture.start()

            pendingPath = relativePath
            self.recorder = recorder
            self.capture = capture
            elapsed = 0
        } catch {
            errorMessage = error.localizedDescription
            await cleanUpFailedRecording()
        }
    }

    private func stopRecording() async {
        capture?.stop()
        capture = nil
        let duration = await recorder?.finish()
        recorder = nil

        guard let duration, let relativePath = pendingPath else {
            errorMessage = "No audio was captured."
            await cleanUpFailedRecording()
            return
        }

        let name = pendingName.trimmingCharacters(in: .whitespaces)
        let speaker = EnrolledSpeaker(name: name, audioPath: relativePath, duration: duration)
        context.insert(speaker)
        do {
            try context.save()
        } catch {
            // The CAF is written but nothing durable points at it, so leaving it would
            // orphan a file nobody can find. Undo the whole enrollment and say so —
            // resetting the form silently would look like it worked.
            context.delete(speaker)
            try? AudioStorage.removeFile(atRelativePath: relativePath)
            errorMessage = error.localizedDescription
            pendingPath = nil
            elapsed = 0
            return
        }

        pendingName = ""
        pendingPath = nil
        elapsed = 0
    }

    /// Don't leave an orphaned sample file behind when enrollment doesn't complete.
    private func cleanUpFailedRecording() async {
        capture?.stop()
        capture = nil
        await recorder?.finish()
        recorder = nil
        if let pendingPath {
            try? AudioStorage.removeFile(atRelativePath: pendingPath)
        }
        pendingPath = nil
        elapsed = 0
    }

    private func remove(_ speaker: EnrolledSpeaker) {
        let audioPath = speaker.audioPath
        context.delete(speaker)
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
