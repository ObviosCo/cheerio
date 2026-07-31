import AVFoundation
import CheerioKit
import Foundation

/// Captures microphone audio via AVAudioEngine and delivers PCM buffers.
/// This is the "Me" channel. Portable to iOS as-is (move to CheerioKit in v2).
final class MicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let onBuffer: @Sendable (sending AVAudioPCMBuffer) -> Void

    init(onBuffer: @escaping @Sendable (sending AVAudioPCMBuffer) -> Void) {
        self.onBuffer = onBuffer
    }

    enum Permission {
        case granted
        /// The user said no, or an administrator disallows it. Only System Settings
        /// can change this — asking again does nothing.
        case denied
    }

    /// Only prompts the first time. Once the user has decided, `requestAccess`
    /// silently returns the stored answer, so re-asking on every recording just
    /// produces the same result — and a dead-end error if it was "no".
    static func permission() async -> Permission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio) ? .granted : .denied
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [onBuffer] buffer, _ in
            // The tap recycles `buffer` after this returns; the transcription
            // engine outlives the callback, so hand it a copy it owns.
            guard let copy = buffer.detachedCopy() else { return }
            onBuffer(copy)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
