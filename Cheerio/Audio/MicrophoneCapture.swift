import AVFoundation
import Foundation

/// Captures microphone audio via AVAudioEngine and delivers PCM buffers.
/// This is the "Me" channel. Portable to iOS as-is (move to CheerioKit in v2).
final class MicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void

    init(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.onBuffer = onBuffer
    }

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [onBuffer] buffer, _ in
            onBuffer(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
