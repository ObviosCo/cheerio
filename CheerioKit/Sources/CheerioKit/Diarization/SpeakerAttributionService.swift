import AVFoundation
import CoreML
import FluidAudio
import Foundation
import OSLog

/// One stretch of audio attributed to a single speaker.
public struct SpeakerTurn: Sendable, Equatable {
    /// The enrolled name if this turn matched an enrolled voice, otherwise a
    /// generated label like "Speaker 2".
    public let label: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval

    public init(label: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.label = label
        self.startTime = startTime
        self.endTime = endTime
    }
}

/// A known voice to prime the diarizer with, so their turns come back named.
public struct SpeakerEnrollment: Sendable {
    public let audioFile: URL
    public let name: String

    public init(audioFile: URL, name: String) {
        self.audioFile = audioFile
        self.name = name
    }
}

/// Separates speakers within a single recorded channel, using Sortformer on the
/// Neural Engine.
///
/// This exists because `SpeechTranscriber` has no speaker surface at all: the
/// mic/system split gives us Me vs Them, but it can't tell three people in a room
/// apart, or two participants on a Zoom call. Runs as a post-pass over the CAF
/// files `MeetingAudioRecorder` writes — so it must run *before* the retention
/// policy purges them.
///
/// The model is never downloaded. Cheerio has no network entitlement, so the app
/// bundles it and passes its URL in.
public actor SpeakerAttributionService {
    public enum AttributionError: Error {
        /// The bundled Core ML model wasn't where we expected it.
        case modelMissing(URL)
    }

    /// Sortformer resolves at most this many distinct speakers. Beyond it, voices
    /// get merged into existing slots rather than gaining new ones.
    public static let maximumSpeakers = 4

    private let modelURL: URL
    private let log = Logger(subsystem: "app.cheerio.mac", category: "SpeakerAttribution")

    public init(modelURL: URL) {
        self.modelURL = modelURL
    }

    /// Diarizes `audioFile`, priming with any known voices first so those speakers
    /// come back under their own names instead of "Speaker 1".
    ///
    /// Enrolled voices consume speaker slots, and there are only
    /// ``maximumSpeakers`` of them — enrolling four people leaves no room for a
    /// fifth voice to be resolved separately.
    public func attribute(
        audioFile: URL,
        enrolling enrollments: [SpeakerEnrollment] = []
    ) async throws -> [SpeakerTurn] {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw AttributionError.modelMissing(modelURL)
        }

        let config = SortformerConfig.default
        let models = try await loadModels(config: config)
        let diarizer = SortformerDiarizer(config: config)
        diarizer.initialize(models: models)

        let converter = AudioConverter()
        if enrollments.count > Self.maximumSpeakers {
            log.error(
                "Enrolling \(enrollments.count, privacy: .public) voices but Sortformer resolves only \(Self.maximumSpeakers, privacy: .public) — later ones will collide"
            )
        }
        // Priming must happen before any real audio is processed; it warms the
        // speaker cache and then resets the timeline to frame 0.
        for enrollment in enrollments {
            let enrollmentSamples = try converter.resampleAudioFile(enrollment.audioFile)
            let speaker = try diarizer.enrollSpeaker(withAudio: enrollmentSamples, named: enrollment.name)
            if speaker == nil {
                log.error(
                    "Couldn't enroll \(enrollment.name, privacy: .public) — no speech detected in \(enrollment.audioFile.lastPathComponent, privacy: .public)"
                )
            }
        }

        let samples = try converter.resampleAudioFile(audioFile)
        let timeline = try diarizer.processComplete(samples)

        // The name from enrollment lives on the speaker. `DiarizerSegment.speakerLabel`
        // is hardcoded to "Speaker \(index)" and never carries it, so reading the
        // segment's label silently discards every enrolled name.
        let turns = timeline.speakers.values
            .flatMap { speaker in
                let label = speaker.name ?? "Speaker \(speaker.index)"
                return speaker.finalizedSegments.map {
                    SpeakerTurn(
                        label: label,
                        startTime: TimeInterval($0.startTime),
                        endTime: TimeInterval($0.endTime)
                    )
                }
            }
            .sorted { $0.startTime < $1.startTime }

        let named = Set(timeline.speakers.values.compactMap(\.name))
        log.notice("Named speakers: \(named.sorted().joined(separator: ", "), privacy: .public)")

        log.notice("Diarized \(audioFile.lastPathComponent, privacy: .public): \(turns.count, privacy: .public) turns")
        return turns
    }
}

extension SpeakerAttributionService {
    /// Loads the model, preferring a pre-compiled `.mlmodelc`.
    ///
    /// `SortformerModels.load(mainModelPath:)` runs `MLModel.compileModel` and so
    /// only accepts an `.mlpackage`. We ship the compiled form instead, which skips
    /// a few hundred milliseconds of compilation on every run and avoids needing a
    /// writable directory for the compiler's output.
    private func loadModels(config: SortformerConfig) async throws -> SortformerModels {
        guard modelURL.pathExtension == "mlmodelc" else {
            return try await SortformerModels.load(config: config, mainModelPath: modelURL)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = SortformerModels.recommendedComputeUnits(for: config)
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        return try SortformerModels(config: config, main: model)
    }
}

extension SpeakerTurn {
    /// Seconds of overlap between this turn and the given window.
    func overlap(start: TimeInterval, end: TimeInterval) -> TimeInterval {
        max(0, min(endTime, end) - max(startTime, start))
    }
}

/// Maps diarized turns onto already-transcribed segments.
public enum SpeakerAttribution {
    /// The label of the turn overlapping `start..<end` the most.
    ///
    /// Transcript segment boundaries and diarization boundaries never line up
    /// exactly, and speech overlaps, so the best we can do is pick the dominant
    /// voice for the window. Returns nil when nothing overlaps.
    public static func dominantLabel(
        start: TimeInterval,
        end: TimeInterval,
        turns: [SpeakerTurn]
    ) -> String? {
        var totalsByLabel: [String: TimeInterval] = [:]
        for turn in turns {
            let overlap = turn.overlap(start: start, end: end)
            guard overlap > 0 else { continue }
            totalsByLabel[turn.label, default: 0] += overlap
        }
        // Most overlap wins. Exact ties fall back to alphabetical order so the result
        // is stable rather than dictionary-ordered — spelled out longhand because the
        // tuple form of this comparator reads like a bug.
        return totalsByLabel.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }?.key
    }
}
