import CheerioKit
import SwiftData
import SwiftUI

/// Records, names, and saves one enrolled voice: the "add a voice" building block
/// shared by Settings → Participants and the onboarding walkthrough's voice-
/// enrollment step, so there is exactly one recorder implementation instead of two
/// that quietly drift apart.
struct VoiceEnrollmentRecorder: View {
    @Environment(\.modelContext) private var context
    /// Voices already marked "me", so saving a new one as "me" can unclaim them —
    /// only one voice can hold that flag at a time.
    @Query(filter: #Predicate<EnrolledSpeaker> { $0.isMe }) private var currentMe: [EnrolledSpeaker]

    /// Onboarding always enrolls your own voice, so it marks `isMe` the moment the
    /// sample is saved. Settings' "Add a voice" enrolls anyone, so it leaves that
    /// decision to the roster's "This is me" button instead.
    var markAsMe = false
    var onSaved: (EnrolledSpeaker) -> Void = { _ in }

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
        let who = markAsMe ? "Keep talking" : "Keep them talking"
        return "\(who) — about \(remaining)s to go."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(markAsMe ? "Your name" : "Name", text: $pendingName)
                .textFieldStyle(.roundedBorder)
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
                // Encouraging, not scary: this used to warn about voices getting
                // mistaken for each other, which read as a threat rather than an
                // invitation. The reason still matters, it's just not the headline.
                Text(
                    "Talk naturally for about \(Int(EnrolledSpeaker.recommendedDuration)) seconds — read something aloud, tell a quick story, anything works. The fuller the sample, the more confidently Cheerio can pick \(markAsMe ? "you" : "them") out of a meeting."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Button("Record voice sample") { Task { await startRecording() } }
                    .disabled(pendingName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .alert("Couldn't record the sample", isPresented: $errorMessage.presented()) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onDisappear {
            // Closing the enclosing sheet/window/tab mid-recording left the
            // microphone running until the view was torn down, and a partial CAF
            // with nothing referencing it.
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
        if markAsMe {
            for other in currentMe { other.isMe = false }
            speaker.isMe = true
        }
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
        onSaved(speaker)
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
}
