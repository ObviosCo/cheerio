import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import OSLog

/// Captures system audio output (everyone else on the call) using a Core Audio
/// process tap (macOS 14.2+). This is the "Them" channel.
///
/// Pipeline: CATapDescription → AudioHardwareCreateProcessTap → aggregate
/// device wrapping the tap → AudioDeviceCreateIOProcIDWithBlock.
///
/// Note: AVAudioEngine cannot read from a tap-backed aggregate device, so we
/// use a raw IOProc and convert AudioBufferList → AVAudioPCMBuffer ourselves.
/// Triggers the system-audio-capture TCC prompt on first use.
final class SystemAudioTap: @unchecked Sendable {
    enum TapError: Error {
        case tapCreationFailed(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case ioProcFailed(OSStatus)
        case formatUnavailable
    }

    private let log = Logger(subsystem: "app.cheerio.mac", category: "SystemAudioTap")
    private let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?

    init(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.onBuffer = onBuffer
    }

    func start() throws {
        // 1. Global tap: all processes' output, mixed to stereo, excluding none.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Cheerio System Audio Tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw TapError.tapCreationFailed(status) }
        self.tapID = tapID

        // 2. Read the tap's stream format.
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw TapError.formatUnavailable
        }
        tapFormat = format

        // 3. Aggregate device wrapping the tap (private, auto-start).
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Cheerio Tap Aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
        guard status == noErr else { throw TapError.aggregateCreationFailed(status) }
        self.aggregateID = aggregateID

        // 4. IOProc: deliver input buffers as AVAudioPCMBuffer.
        let onBuffer = self.onBuffer
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, inputData, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil)
            else { return }
            onBuffer(buffer)
        }
        guard status == noErr, let ioProcID else { throw TapError.ioProcFailed(status) }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else { throw TapError.ioProcFailed(status) }
        log.info("System audio tap started")
    }

    func stop() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        log.info("System audio tap stopped")
    }
}
