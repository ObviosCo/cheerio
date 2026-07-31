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
                Text("At most \(SpeakerAttributionService.maximumSpeakers) voices are used per meeting — enrolled voices take slots that unenrolled participants would otherwise get.")
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
                        Button("Stop and save") { Task { await stopRecording() } }
                            .keyboardShortcut(.defaultAction)
                    }
                    Text("Talk naturally for at least \(Int(EnrolledSpeaker.recommendedDuration)) seconds. Shorter samples get confused with similar voices.")
                        .font(.caption)
                        .foregroundStyle(elapsed >= EnrolledSpeaker.recommendedDuration ? .green : .secondary)
                } else {
                    Button("Record voice sample") { Task { await startRecording() } }
                        .disabled(pendingName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 420)
        .alert("Couldn't record the sample", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
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
                Text(speaker.name)
                Text(durationLabel(for: speaker))
                    .font(.caption)
                    .foregroundStyle(speaker.hasEnoughAudio ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            }
            Spacer()
            Button("Remove", role: .destructive) { remove(speaker) }
                .buttonStyle(.borderless)
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
        context.insert(EnrolledSpeaker(name: name, audioPath: relativePath, duration: duration))
        try? context.save()

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
        try? AudioStorage.removeFile(atRelativePath: speaker.audioPath)
        context.delete(speaker)
        try? context.save()
    }
}
