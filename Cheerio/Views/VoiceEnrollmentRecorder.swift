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
    /// Guards the `recorder.finish()` transition. `finish()` suspends, and while it's
    /// suspended `recorder` is still non-nil — so `isRecording` still reads true and
    /// the Save button is still enabled, and the view can still disappear. Without
    /// this flag, a second tap of Save, or `onDisappear` firing mid-save, would call
    /// `finish()` again concurrently: two saves racing (possible duplicate
    /// `EnrolledSpeaker`), or `onDisappear`'s cleanup deleting `pendingPath` out from
    /// under a save that goes on to reference it.
    ///
    /// Both `stopRecording()` and `onDisappear` check-and-set this synchronously,
    /// with no `await` in between, before doing anything else — whichever runs
    /// first wins, and the other becomes a no-op. That makes the two outcomes
    /// mutually exclusive: either the in-flight save completes, or (if
    /// `onDisappear` won the race) it's cancelled and cleaned up — never both.
    @State private var isFinalizing = false
    /// Guards the `startRecording()` transition, the mirror image of
    /// `isFinalizing` above. `startRecording()` suspends at the permission
    /// prompt and again while the recorder/capture spin up, and while it's
    /// suspended `recorder` is still nil — so `isRecording` still reads false,
    /// the "Record voice sample" button is still enabled, and the view can
    /// still disappear. Without this flag: a double-click could run
    /// `startRecording()` twice concurrently, each writing its own
    /// `pendingPath`/`capture`/`recorder` and clobbering the other's; and
    /// leaving the view during the permission request would let `onDisappear`
    /// run its cleanup while `isRecording == false` (nothing to stop yet), then
    /// let `startRecording` resume afterward and start a capture with no
    /// cleanup path left pointed at it.
    ///
    /// Set synchronously, before the first `await` in `startRecording()`, so a
    /// second click sees it already set and no-ops. Tracked as a `Task` handle
    /// so `onDisappear` can cancel it outright; `startRecording` checks
    /// `Task.isCancelled` after each `await` and tears down anything it had
    /// already created before returning.
    @State private var isStarting = false
    @State private var startTask: Task<Void, Never>?

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
                    .disabled(isFinalizing)
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
                Button("Record voice sample") {
                    // Check-and-set `isStarting` synchronously, before the `Task`
                    // (or anything else) runs, so a second click sees it already
                    // set and no-ops instead of racing this one — see the comment
                    // on `isStarting`.
                    guard !isStarting else { return }
                    isStarting = true
                    startTask = Task {
                        await startRecording()
                        isStarting = false
                        startTask = nil
                    }
                }
                .disabled(isStarting || pendingName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .alert("Couldn't record the sample", isPresented: $errorMessage.presented()) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onDisappear {
            // Cancel an in-flight start before it can land. `startRecording` suspends
            // at the permission prompt and again while spinning up the recorder and
            // capture, and during that whole window `isRecording` still reads false —
            // so the guard below wouldn't catch it. Cancelling relies on
            // `startRecording` noticing `Task.isCancelled` after each `await` and
            // unwinding anything it had already created; see its cancellation checks.
            if isStarting {
                startTask?.cancel()
            }

            // Closing the enclosing sheet/window/tab mid-recording left the
            // microphone running until the view was torn down, and a partial CAF
            // with nothing referencing it.
            //
            // Check-and-set `isFinalizing` synchronously, before the `Task` below
            // (or anything else) runs, so this races safely against `stopRecording()`
            // — see the comment on `isFinalizing`. If a save is already in flight,
            // this is a no-op and the save is left to finish on its own.
            guard isRecording, !isFinalizing else { return }
            isFinalizing = true
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
        // `onDisappear` may have cancelled us while we were suspended at the
        // permission prompt above. Nothing has been created yet, so bailing out
        // here is a plain no-op — but skip the alert, since the view is on its
        // way out and there's no one left to read it.
        guard !Task.isCancelled else { return }

        do {
            let (relativePath, url) = try AudioStorage.makeSpeakerSampleFile()
            let recorder = VoiceSampleRecorder(destination: url)
            await recorder.start()
            guard !Task.isCancelled else {
                // Cancelled while `recorder.start()` was suspended: the recorder
                // exists and has a file on disk, but neither is published to
                // `self` yet, so `onDisappear`'s own cleanup can't see them. Tear
                // down what we made ourselves instead of leaking it.
                await recorder.finish()
                try? AudioStorage.removeFile(atRelativePath: relativePath)
                return
            }

            let capture = MicrophoneCapture { buffer in recorder.submit(buffer) }
            // Published *before* the throwing call: if `capture.start()` throws
            // after partially installing the tap, the catch below can only unwind
            // what `cleanUpFailedRecording()` can see on `self` — as locals, the
            // recorder's drain task and the tap would leak.
            pendingPath = relativePath
            self.recorder = recorder
            self.capture = capture
            // Always in-person: this is a close-mic'd reference sample of one voice with
            // no speaker playback to cancel, and issue #5's design comment already flags
            // AEC as liable to alter the very characteristics enrollment depends on.
            try capture.start(mode: .inPerson)
            guard !Task.isCancelled else {
                // Cancelled while the microphone was coming up: everything is
                // published now, so the shared cleanup can unwind all of it.
                await cleanUpFailedRecording()
                return
            }
            elapsed = 0
        } catch {
            errorMessage = error.localizedDescription
            await cleanUpFailedRecording()
        }
    }

    private func stopRecording() async {
        // Check-and-set `isFinalizing` synchronously, before the first `await`
        // below, so a second tap of Save (or `onDisappear` firing mid-save) sees
        // it already set and becomes a no-op instead of racing this call — see
        // the comment on `isFinalizing`.
        guard !isFinalizing else { return }
        isFinalizing = true
        defer { isFinalizing = false }

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
        // Snapshot exactly who this is about to demote, so a failed save can put
        // back exactly that — not everything in the context. See below for why
        // `context.rollback()` isn't the tool for that.
        let previouslyMe = markAsMe ? currentMe : []
        if markAsMe {
            for other in currentMe { other.isMe = false }
            speaker.isMe = true
        }
        context.insert(speaker)
        do {
            try context.save()
        } catch {
            // The CAF is written but nothing durable points at it, so leaving it would
            // orphan a file nobody can find. Undo the enrollment and say so — resetting
            // the form silently would look like it worked.
            //
            // This context is shared with the rest of the scene, and this recorder can
            // run *during* an active recording (RecordingView's enrollment nudge), while
            // CaptureSession leaves the live meeting's transcript segments unsaved in
            // this same context until stop. `context.rollback()` discards every pending
            // change in the context, not just this method's — it would throw away part
            // of the meeting in progress along with the failed enrollment. Undo only
            // what this method touched instead: drop the speaker we just inserted (it
            // was never persisted, so deleting it cancels the insert rather than
            // recording a delete) and restore `isMe` on exactly the speakers we flipped.
            context.delete(speaker)
            for other in previouslyMe { other.isMe = true }
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
