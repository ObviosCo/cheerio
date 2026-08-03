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
        let (roster, dropped) = meeting.participants(
            from: allEnrolled(context: context),
            limit: SpeakerAttributionService.maximumSpeakers
        )
        if !dropped.isEmpty {
            // Never truncate quietly: someone who was in the room coming back as
            // "Speaker 2" with no explanation is the failure this roster exists to stop.
            log.error(
                "Speaker cap left out \(dropped.map(\.name).joined(separator: ", "), privacy: .public) — deselect someone in this meeting's roster"
            )
        }

        // Each channel is diarized against its own recording: in-room voices land on
        // the mic, remote participants on the system tap.
        var labelledAnything = false
        for channel in [SpeakerChannel.me, .them] {
            let audioFile = directory.appending(path: "\(channel.rawValue).caf")
            guard FileManager.default.fileExists(atPath: audioFile.path) else { continue }

            // You can't be on the far end of your own call, so priming your voice
            // against the system tap would burn a slot a remote participant needs.
            let forChannel = channel == .them ? roster.filter { !$0.isMe } : roster
            let turns = try await service.attribute(
                audioFile: audioFile,
                enrolling: enrollments(for: forChannel)
            )
            guard !turns.isEmpty else { continue }

            // Manually named lines are left alone: a person who corrected a label
            // outranks the model, and clobbering that would make correcting pointless.
            for segment in meeting.segments
            where segment.channel == channel && !segment.isSpeakerLabelManual {
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
            // Not `try?`: a failed save means the labels the user is looking at will be
            // gone on next launch, which they need to know about.
            try context.save()
        } else {
            throw LabelingError.audioUnavailable
        }
    }

    /// Every enrolled voice, oldest first. Which of them apply to a given meeting is
    /// ``Meeting/participants(from:limit:)``' call, not ours.
    static func allEnrolled(context: ModelContext) -> [EnrolledSpeaker] {
        let descriptor = FetchDescriptor<EnrolledSpeaker>(
            sortBy: [SortDescriptor(\.enrolledAt, order: .forward)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Turns a roster into something the diarizer can be primed with, skipping anyone
    /// whose sample file has gone missing.
    static func enrollments(for speakers: [EnrolledSpeaker]) -> [SpeakerEnrollment] {
        speakers.compactMap { speaker in
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
