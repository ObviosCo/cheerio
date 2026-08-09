import AVFoundation
import CheerioKit
import Foundation

/// Plays back one meeting's retained audio as a single merged track.
///
/// One instance per meeting, owned by the view that shows it — see
/// `MeetingAudioPlayerView`, which keys that view's identity on the meeting so
/// switching meetings tears this down rather than reusing it against a different
/// asset. This class never touches `Meeting` or `ModelContext` itself: it's
/// handed the URLs `MeetingAudioPlayback.channelFileURLs(for:)` already found on
/// disk, so it can't be asked to play a meeting whose audio was never checked to
/// exist.
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

    /// Builds the merged composition and prepares an `AVPlayer` over it. Safe to
    /// call once per instance — `MeetingAudioPlayerView` creates a fresh model
    /// per meeting rather than reloading this one.
    func load(urls: [URL]) async {
        do {
            let composition = try await MeetingAudioPlayback.makeComposition(from: urls)
            duration = try await composition.load(.duration).seconds
            let player = AVPlayer(playerItem: AVPlayerItem(asset: composition))
            self.player = player
            observe(player)
        } catch {
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

    func play() {
        player?.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    /// Called on a recording starting and on this view disappearing — a paused
    /// position rather than a reset, since dismissing the detail view and coming
    /// straight back (the sidebar re-selecting the same meeting) shouldn't lose
    /// where playback was.
    func seek(to time: TimeInterval) {
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        currentTime = time
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
