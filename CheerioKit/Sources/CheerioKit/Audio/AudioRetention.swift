import Foundation
import OSLog
import SwiftData

/// How long recorded audio is kept on disk. Transcripts and notes are never
/// affected — only the raw CAF files.
///
/// The raw value is the number of days, stored directly in `UserDefaults` under
/// ``AudioRetention/defaultsKey`` so the setting can be read with `@AppStorage`.
public enum AudioRetention: Int, CaseIterable, Identifiable, Sendable {
    /// Discard audio as soon as the meeting finishes.
    case none = 0
    case day = 1
    case week = 7
    case month = 30
    case forever = -1

    public static let defaultsKey = "audioRetentionDays"
    /// Privacy-leaning default, per the spec.
    public static let `default` = AudioRetention.week

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .none: "Don't keep audio"
        case .day: "24 hours"
        case .week: "7 days"
        case .month: "30 days"
        case .forever: "Forever"
        }
    }

    /// The setting as stored by the Settings UI's `@AppStorage`, for code that
    /// isn't a view.
    public static var current: AudioRetention {
        let stored = UserDefaults.standard.object(forKey: defaultsKey) as? Int
        return stored.flatMap(AudioRetention.init(rawValue:)) ?? .default
    }

    /// Meetings that ended before this date should have their audio removed.
    /// `nil` means keep everything.
    func purgeCutoff(now: Date) -> Date? {
        switch self {
        case .forever: nil
        case .none: now
        case .day, .week, .month: now.addingTimeInterval(-Double(rawValue) * 86_400)
        }
    }
}

/// Applies the retention policy by deleting expired audio directories and clearing
/// the corresponding `Meeting.audioDirectory` references.
public enum AudioRetentionService {
    private static let log = Logger(subsystem: "co.obvios.cheerio.mac", category: "AudioRetention")

    /// Call at launch and after each recording finishes.
    /// Returns the number of meetings whose audio was removed.
    @discardableResult
    public static func purge(
        retention: AudioRetention,
        context: ModelContext,
        now: Date = .now
    ) throws -> Int {
        guard let cutoff = retention.purgeCutoff(now: now) else { return 0 }

        // Only finished meetings — never touch a recording in progress.
        let descriptor = FetchDescriptor<Meeting>(
            predicate: #Predicate { $0.audioDirectory != nil && $0.endedAt != nil }
        )
        var removed = 0
        for meeting in try context.fetch(descriptor) {
            // A meeting still carrying a pending plan is held, not finished
            // (issue #136): capture stopped — so `endedAt` is set and the
            // predicate above matches — but diarization hasn't consumed its
            // audio yet, and diarization reads exactly these CAF files. With
            // "Don't keep audio" the cutoff is *now*, so without this a hold, or
            // a held meeting waiting for launch recovery, would lose its audio
            // before speaker labelling ever saw it. Checked in the loop rather
            // than the predicate because `#Predicate` can't reach into an
            // optional composite. The pass after processing (`CaptureSession`
            // runs one at every conclusion) picks these up once the plan clears.
            guard meeting.pendingProcessingPlan == nil else { continue }
            guard let endedAt = meeting.endedAt, endedAt < cutoff,
                let relativePath = meeting.audioDirectory
            else { continue }
            do {
                try AudioStorage.removeDirectory(atRelativePath: relativePath)
                meeting.audioDirectory = nil
                removed += 1
            } catch {
                log.error("Couldn't remove audio at \(relativePath, privacy: .public): \(error)")
            }
        }
        if removed > 0 {
            try context.save()
            log.info("Purged audio for \(removed, privacy: .public) meeting(s)")
        }
        return removed
    }
}
