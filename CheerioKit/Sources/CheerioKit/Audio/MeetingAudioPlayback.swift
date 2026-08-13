import AVFoundation
import Foundation

/// Whether a meeting's recorded audio is still on disk, and how to turn its
/// per-channel CAF files into one asset an `AVPlayer` can play back.
///
/// `Meeting.audioDirectory` going nil means retention purged the files; the
/// directory can also exist with nothing in it, or with only one channel, if
/// `MeetingAudioRecorder` never got a chance to write the other (a failed file
/// open, or a meeting that never had system audio). Every caller goes through
/// ``channelFileURLs(for:resolve:)`` rather than checking `audioDirectory` alone,
/// so all three of those collapse into the same answer: nothing to play.
public enum MeetingAudioPlayback {
    /// Every capture channel that actually wrote a file for this meeting, paired
    /// with the file, in a fixed order (``SpeakerChannel/me`` before
    /// ``SpeakerChannel/them``) — deliberately not a `Set`, so a caller building
    /// a composition always layers the mic track first regardless of which
    /// channel happened to finish writing first.
    ///
    /// Which channel a file belongs to matters to anything that acts on one
    /// channel at a time — re-transcription (issue #14) repairs a single
    /// channel's transcript — while playback mixes them and only needs the URLs;
    /// ``channelFileURLs(for:resolve:)`` is that narrower view of this same
    /// answer.
    ///
    /// `resolve` defaults to `AudioStorage.url(forRelativePath:)` and exists as a
    /// parameter for the same reason `AudioOrphanSweep.sweep`'s directory
    /// parameter does: tests need this off the real Application Support
    /// container.
    public static func channelFiles(
        for meeting: Meeting,
        resolve: (String) throws -> URL = AudioStorage.url(forRelativePath:)
    ) -> [(channel: SpeakerChannel, url: URL)] {
        guard let relativePath = meeting.audioDirectory,
            let directory = try? resolve(relativePath)
        else { return [] }
        return [SpeakerChannel.me, .them].compactMap { channel in
            let url = directory.appending(path: "\(channel.rawValue).caf")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return (channel, url)
        }
    }

    /// The files ``channelFiles(for:resolve:)`` found, for callers that mix the
    /// channels rather than treating them separately.
    public static func channelFileURLs(
        for meeting: Meeting,
        resolve: (String) throws -> URL = AudioStorage.url(forRelativePath:)
    ) -> [URL] {
        channelFiles(for: meeting, resolve: resolve).map(\.url)
    }

    /// Whether the meeting detail view should show a playback affordance at all.
    /// Purged or never-recorded audio look identical from here on purpose — both
    /// mean "show nothing," not a disabled control that implies playback is
    /// broken rather than simply unavailable.
    public static func hasPlayableAudio(
        for meeting: Meeting,
        resolve: (String) throws -> URL = AudioStorage.url(forRelativePath:)
    ) -> Bool {
        !channelFileURLs(for: meeting, resolve: resolve).isEmpty
    }

    /// Where a tap on a transcript segment should put the playhead.
    ///
    /// `TranscriptSegment.startTime` is already seconds-from-meeting-start, and
    /// ``makeComposition(from:)`` lays every channel down at time zero, so the
    /// segment's clock and the composition's clock are the same axis — no
    /// channel offset to translate. What still needs handling is the edges:
    /// transcription can finalize a segment timestamped past the shorter (or
    /// only) channel's end, and a player mid-load reports a zero or non-finite
    /// duration, so the target is clamped into `[0, duration - endMargin]`
    /// rather than handed to `AVPlayer.seek` raw. The margin matters as much
    /// as the clamp: the caller seeks and immediately plays, and playing from
    /// the exact end fires `AVPlayerItemDidPlayToEndTime` at once — the
    /// played-to-end reset to zero this helper exists to avoid — so an
    /// overshoot has to land audibly *inside* the audio, not on its edge.
    public static func seekTime(
        forSegmentStart startTime: TimeInterval,
        duration: TimeInterval
    ) -> TimeInterval {
        guard startTime.isFinite, duration.isFinite, duration > 0 else { return 0 }
        return min(max(0, startTime), max(0, duration - endMargin))
    }

    /// How far short of the end an overshooting (or nearly-ending) segment
    /// lands. Half a second is enough playable audio for the tap to read as
    /// "jumped to the end" rather than as a no-op that snapped back to 0:00;
    /// audio shorter than the margin collapses to the start, where the same
    /// holds trivially.
    private static let endMargin: TimeInterval = 0.5

    /// Merges every channel that recorded into one asset, so the meeting plays
    /// back as a single listening experience rather than a per-channel picker.
    ///
    /// Each file becomes its own audio track spanning its full duration at time
    /// zero. `AVPlayer` mixes every enabled track of a player item down to the
    /// output automatically — that's the entire trick, and it's why this doesn't
    /// need an `AVAudioEngine` mixer graph or any manual sample math: two tracks
    /// that both need to play from the start is exactly the case a composition
    /// handles for free. A channel that recorded for less time than the other
    /// just runs out first — silence for the rest, not truncation of the longer
    /// one.
    public static func makeComposition(from urls: [URL]) async throws -> AVComposition {
        let composition = AVMutableComposition()
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            guard
                let compositionTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                )
            else { continue }
            let duration = try await asset.load(.duration)
            try compositionTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: sourceTrack,
                at: .zero
            )
        }
        return composition
    }
}
