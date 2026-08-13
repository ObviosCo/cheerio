import AVFoundation
import AudioToolbox
import CheerioKit
import CoreAudio
import Foundation
import OSLog
import Synchronization

/// Captures system audio output (everyone else on the call) using a Core Audio
/// process tap (macOS 14.2+). This is the "Them" channel.
///
/// Pipeline: CATapDescription → AudioHardwareCreateProcessTap → aggregate
/// device wrapping the tap → AudioDeviceCreateIOProcIDWithBlock.
///
/// Note: AVAudioEngine cannot read from a tap-backed aggregate device, so we
/// use a raw IOProc and convert AudioBufferList → AVAudioPCMBuffer ourselves.
/// Triggers the system-audio-capture TCC prompt on first use.
/// Tracks whether a tap ever produced a non-zero sample, scanning only the opening
/// seconds so the audio callback's cost stays bounded.
private final class SilenceWatch: Sendable {
    private let framesInspected = Atomic<Int>(0)
    private let sawSignal = Atomic<Bool>(false)
    /// Roughly two seconds at any sane sample rate.
    private let frameBudget = 96_000 * 2
    /// Cap on one callback's scan, so a large buffer can't stretch it.
    private let framesPerCallback = 4_096

    var didSeeSignal: Bool { sawSignal.load(ordering: .acquiring) }

    /// Realtime-safe: lock-free, and bounded both per callback and overall.
    ///
    /// The original took an `NSLock` here on every buffer. Sample scanning was never
    /// the problem — a few thousand float compares is nothing next to the
    /// `detachedCopy()` this callback already does — but locking on the audio thread
    /// risks priority inversion against whoever reads `didSeeSignal`, and that's the
    /// one thing a realtime callback must never do.
    func inspect(_ buffer: AVAudioPCMBuffer) {
        guard !sawSignal.load(ordering: .relaxed) else { return }
        let seen = framesInspected.wrappingAdd(Int(buffer.frameLength), ordering: .relaxed).oldValue
        guard seen < frameBudget else { return }

        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        var budget = framesPerCallback
        for index in 0..<list.count {
            guard let data = list[index].mData else { continue }
            let count = min(Int(list[index].mDataByteSize) / 4, budget)
            let samples = data.bindMemory(to: Float.self, capacity: count)
            for sample in 0..<count where samples[sample] != 0 {
                sawSignal.store(true, ordering: .releasing)
                return
            }
            budget -= count
            if budget <= 0 { return }
        }
    }
}

final class SystemAudioTap: @unchecked Sendable {
    enum TapError: Error {
        case tapCreationFailed(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case ioProcFailed(OSStatus)
        case formatUnavailable
    }

    private let log = Logger(subsystem: "co.obvios.cheerio.mac", category: "SystemAudioTap")
    private let onBuffer: @Sendable (sending AVAudioPCMBuffer) -> Void

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?

    /// A tap that is denied doesn't fail — it delivers zeroes forever. This watches
    /// the opening seconds for any non-zero sample so `stop()` can say so out loud.
    private let signalWatch = SilenceWatch()

    /// Whether `stop()` logs the silence/signal verdict at all. Defaults on for the
    /// real capture path, where minutes of silence really does mean a denied tap.
    /// The onboarding probe (`OnboardingPermissionStepView.requestSystemAudio()`)
    /// opts out: it only runs the tap for ~1 second to trigger the TCC prompt, and
    /// a quiet Mac in that one second looks identical to a denied tap — logging the
    /// verdict there would be a false alarm, not a diagnosis. Production logging is
    /// unaffected by this flag; it stays on unless a caller explicitly opts out.
    private let logsSilenceVerdict: Bool

    init(
        logsSilenceVerdict: Bool = true,
        onBuffer: @escaping @Sendable (sending AVAudioPCMBuffer) -> Void
    ) {
        self.logsSilenceVerdict = logsSilenceVerdict
        self.onBuffer = onBuffer
    }

    /// Whether the tap saw any nonzero sample in the opening seconds — see
    /// `SilenceWatch`, whose window is why `false` here is weaker evidence than the
    /// mic's peak verdict. `CaptureSession` pairs it with the transcript's segment
    /// count (`TranscriptionCoverage`).
    var didCaptureSignal: Bool {
        signalWatch.didSeeSignal
    }

    /// The tap's own stream format, read from `kAudioTapPropertyFormat` at start and
    /// kept past `stop()` so the verdict can name it. The scalars rather than the
    /// `AVAudioFormat` for the same reason the mic's are — see `CapturedAudioFormat`.
    var capturedFormat: CapturedAudioFormat? {
        tapFormat.map(CapturedAudioFormat.init)
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
        let signalWatch = self.signalWatch
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, inputData, _, _, _ in
            // `inputData` belongs to Core Audio and is recycled as soon as this
            // block returns, so wrap it without copying and then take a copy we own.
            guard let transient = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil),
                let buffer = transient.detachedCopy()
            else { return }
            signalWatch.inspect(buffer)
            onBuffer(buffer)
        }
        guard status == noErr, let ioProcID else { throw TapError.ioProcFailed(status) }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else { throw TapError.ioProcFailed(status) }
        // .notice so it survives to `log show`; .info is memory-only.
        log.notice("System audio tap started — \(format.sampleRate, privacy: .public)Hz ch=\(format.channelCount, privacy: .public)")
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

        guard logsSilenceVerdict else { return }
        if signalWatch.didSeeSignal {
            log.notice("System audio tap stopped — captured signal")
        } else {
            log.error(
                """
                System audio tap stopped — captured ONLY SILENCE. The tap was created \
                without error but every sample was zero, which means macOS is denying \
                capture rather than failing. Check System Settings → Privacy & Security \
                → Screen & System Audio Recording, and whether this build is sandboxed.
                """
            )
        }
    }
}
