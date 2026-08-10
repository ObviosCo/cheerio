import AVFoundation
import CheerioKit
import Foundation

/// Plays back one meeting's retained audio as a single merged track.
///
/// One instance per meeting, owned by `MeetingDetailView` rather than the player
/// controls that render it — the transcript's tap-to-seek (#123) needs to reach
/// the same player the scrubber drives, and the detail view is the nearest
/// ancestor both of them share. That view is *reused* across a sidebar selection
/// change, not recreated, so its meeting-keyed `.task` replaces this instance
/// wholesale (teardown, fresh model, fresh `load`) instead of keying identity
/// through `.id` the way the controls' `@State` version once did. This class
/// never touches `Meeting` or `ModelContext` itself: it's handed the URLs
/// `MeetingAudioPlayback.channelFileURLs(for:)` already found on disk, so it
/// can't be asked to play a meeting whose audio was never checked to exist.
@MainActor
@Observable
final class MeetingAudioPlayerModel {
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    /// Set only when the files exist but the asset itself couldn't be loaded
    /// (a corrupt or truncated CAF). Distinct from "no audio for this meeting,"
    /// which the caller already ruled out before constructing this at all — see
    /// `MeetingAudioPlayback.hasPlayableAudio`.
    private(set) var loadError: String?

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    /// Whether `load(urls:)` has finished and there's a real `AVPlayer` behind
    /// this model. `MeetingAudioPlayerView` disables the controls until this is
    /// true, which is the fix for the window between this model existing and its
    /// `.task` finishing — but `play()` below guards on it independently too,
    /// so `isPlaying` can't end up true for a tap that lands in that window
    /// regardless of what the view happened to be showing at the time.
    var isReady: Bool { player != nil }

    /// Builds the merged composition and prepares an `AVPlayer` over it. Safe to
    /// call once per instance — `MeetingDetailView` creates a fresh model per
    /// meeting rather than reloading this one.
    func load(urls: [URL]) async {
        do {
            let composition = try await MeetingAudioPlayback.makeComposition(from: urls)
            let seconds = try await composition.load(.duration).seconds
            // The owning `.task(id:)` cancels when the sidebar selects another
            // meeting, and by then this instance has already been replaced —
            // finishing the load would stand up a player, and a periodic time
            // observer retaining it, that nothing will ever tear down.
            guard !Task.isCancelled else { return }
            duration = seconds
            let player = AVPlayer(playerItem: AVPlayerItem(asset: composition))
            self.player = player
            observe(player)
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
        }
    }

    private func observe(_ player: AVPlayer) {
        // A quarter-second cadence is plenty for a scrubber label that only shows
        // whole seconds — anything tighter is redraw work the UI can't show.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            // `queue: .main` above is what makes this safe, not a promise the
            // compiler can see on its own — same reasoning as the end-of-track
            // observer below.
            MainActor.assumeIsolated {
                self?.currentTime = time.seconds
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
                self?.currentTime = 0
                self?.player?.seek(to: .zero)
            }
        }
    }

    /// No-op without a loaded player — `isPlaying` must never say something the
    /// player itself can't back up, so this checks rather than trusting the
    /// caller to have gone through `isReady` first.
    func play() {
        guard let player else { return }
        player.play()
        isPlaying = true
    }

    func pause() {
        isPlaying = false
        player?.pause()
    }

    /// Called on a recording starting and on this view disappearing — a paused
    /// position rather than a reset, since dismissing the detail view and coming
    /// straight back (the sidebar re-selecting the same meeting) shouldn't lose
    /// where playback was.
    func seek(to time: TimeInterval) {
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        currentTime = time
    }

    /// The transcript's tap-to-seek (#123): put the playhead at a segment's
    /// start and make sure something is audible — a tap that lands while
    /// playback is stopped starts it there rather than silently moving a
    /// paused playhead. Clamping lives in `MeetingAudioPlayback.seekTime` so
    /// the edge cases (a segment finalized past the audio's end, a duration
    /// the asset hasn't reported yet) are covered by CheerioKit's tests, not
    /// re-derived here.
    func playFrom(_ segmentStart: TimeInterval) {
        guard player != nil else { return }
        seek(to: MeetingAudioPlayback.seekTime(forSegmentStart: segmentStart, duration: duration))
        play()
    }

    func teardown() {
        pause()
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player = nil
    }
}
