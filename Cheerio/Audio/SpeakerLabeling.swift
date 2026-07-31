import CheerioKit
import Foundation
import OSLog
import SwiftData

/// Runs speaker diarization over a meeting's recorded audio and labels its
/// transcript segments.
///
/// Used both at the end of a recording and on demand afterwards — labels can
/// improve after the fact as more voices get enrolled, and the audio is still on
/// disk until the retention policy purges it.
@MainActor
enum SpeakerLabeling {
    private static let log = Logger(subsystem: "app.cheerio.mac", category: "SpeakerLabeling")

    enum LabelingError: LocalizedError {
        case modelMissing
        case audioUnavailable

        var errorDescription: String? {
            switch self {
            case .modelMissing:
                "The speaker model isn't in the app bundle. Run Scripts/fetch-models.sh and rebuild."
            case .audioUnavailable:
                "This meeting's audio has been deleted, so speakers can't be identified. Check the retention setting in Settings → Privacy."
            }
        }
    }

    /// Labels every segment it can. Throws only when it couldn't run at all —
    /// a meeting whose audio is gone, or a missing model.
    static func label(meeting: Meeting, context: ModelContext) async throws {
        guard let modelURL = BundledModels.speakerDiarization else { throw LabelingError.modelMissing }
        guard let relativePath = meeting.audioDirectory,
              let directory = try? AudioStorage.url(forRelativePath: relativePath),
              FileManager.default.fileExists(atPath: directory.path)
        else { throw LabelingError.audioUnavailable }

        let service = SpeakerAttributionService(modelURL: modelURL)
        let enrollments = enrollments(context: context)

        // Each channel is diarized against its own recording: in-room voices land on
        // the mic, remote participants on the system tap.
        var labelledAnything = false
        for channel in [SpeakerChannel.me, .them] {
            let audioFile = directory.appending(path: "\(channel.rawValue).caf")
            guard FileManager.default.fileExists(atPath: audioFile.path) else { continue }

            let turns = try await service.attribute(audioFile: audioFile, enrolling: enrollments)
            guard !turns.isEmpty else { continue }

            for segment in meeting.segments where segment.channel == channel {
                segment.speakerLabel = SpeakerAttribution.dominantLabel(
                    start: segment.startTime,
                    end: segment.endTime,
                    turns: turns
                )
            }
            labelledAnything = true
            log.notice(
                "Labeled \(channel.rawValue, privacy: .public) from \(turns.count, privacy: .public) turns"
            )
        }

        if labelledAnything {
            try? context.save()
        } else {
            throw LabelingError.audioUnavailable
        }
    }

    /// Known voices to prime the diarizer with. Anyone not enrolled comes back as
    /// "Speaker 1", "Speaker 2", …
    ///
    /// Capped at the diarizer's speaker limit, oldest enrollments first, since
    /// enrolled voices consume slots unenrolled participants would otherwise get.
    static func enrollments(context: ModelContext) -> [SpeakerEnrollment] {
        let descriptor = FetchDescriptor<EnrolledSpeaker>(
            sortBy: [SortDescriptor(\.enrolledAt, order: .forward)]
        )
        guard let speakers = try? context.fetch(descriptor) else { return [] }

        return speakers.prefix(SpeakerAttributionService.maximumSpeakers).compactMap { speaker in
            guard let url = try? AudioStorage.url(forRelativePath: speaker.audioPath),
                  FileManager.default.fileExists(atPath: url.path)
            else {
                log.error("Voice sample missing for \(speaker.name, privacy: .public)")
                return nil
            }
            return SpeakerEnrollment(audioFile: url, name: speaker.name)
        }
    }
}
