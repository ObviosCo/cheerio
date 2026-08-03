import AVFoundation
import Foundation

/// Copies selected stretches of a recording into a new file.
///
/// Exists so one speaker's turns can be lifted out of a finished meeting and reused
/// as their enrollment sample — enrolling from audio you already have beats asking a
/// colleague to talk into your Mac for 30 seconds.
public enum AudioExcerpt {
    public struct Range: Sendable, Equatable {
        public let start: TimeInterval
        public let end: TimeInterval

        public init(start: TimeInterval, end: TimeInterval) {
            self.start = start
            self.end = end
        }
    }

    public enum ExcerptError: LocalizedError {
        /// Every requested range fell outside the recording, or had no length.
        case noAudioInRanges

        public var errorDescription: String? {
            switch self {
            case .noAudioInRanges: "That speaker's audio couldn't be found in the recording."
            }
        }
    }

    /// Writes `ranges` from `source` into a new file at `destination`, back to back,
    /// and returns how many seconds were written.
    ///
    /// Ranges are merged and clamped to the recording first, so overlapping turns
    /// don't duplicate audio and a range running past the end is truncated rather
    /// than failing.
    @discardableResult
    public static func write(
        _ ranges: [Range],
        from source: URL,
        to destination: URL
    ) throws -> TimeInterval {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let sampleRate = format.sampleRate
        let frameCount = input.length
        let output = try AVAudioFile(forWriting: destination, settings: input.fileFormat.settings)

        var framesWritten: AVAudioFramePosition = 0
        for range in merging(ranges) {
            let start = clamp(AVAudioFramePosition((range.start * sampleRate).rounded()), to: frameCount)
            let end = clamp(AVAudioFramePosition((range.end * sampleRate).rounded()), to: frameCount)
            guard end > start else { continue }

            input.framePosition = start
            var remaining = AVAudioFrameCount(end - start)
            // Read in chunks so excerpting a long turn doesn't allocate it all at once.
            while remaining > 0 {
                let wanted = min(chunkFrames, remaining)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: wanted) else { break }
                try input.read(into: buffer, frameCount: wanted)
                guard buffer.frameLength > 0 else { break }
                try output.write(from: buffer)
                framesWritten += AVAudioFramePosition(buffer.frameLength)
                remaining -= buffer.frameLength
            }
        }

        guard framesWritten > 0 else { throw ExcerptError.noAudioInRanges }
        return Double(framesWritten) / sampleRate
    }

    private static let chunkFrames: AVAudioFrameCount = 1 << 15

    private static func clamp(_ frame: AVAudioFramePosition, to length: AVAudioFramePosition) -> AVAudioFramePosition {
        min(max(0, frame), length)
    }

    /// Sorted, with overlapping and touching ranges combined.
    static func merging(_ ranges: [Range]) -> [Range] {
        let sorted = ranges.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var merged: [Range] = []
        for range in sorted {
            if let last = merged.last, range.start <= last.end {
                merged[merged.count - 1] = Range(start: last.start, end: max(last.end, range.end))
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
