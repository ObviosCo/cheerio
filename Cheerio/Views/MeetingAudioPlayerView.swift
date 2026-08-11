import CheerioKit
import SwiftUI

/// The playback controls for a meeting's retained audio.
///
/// This view renders the player; it doesn't own it. `MeetingDetailView` holds
/// the `MeetingAudioPlayerModel` — created fresh and loaded per meeting in its
/// meeting-keyed `.task` — because the transcript's tap-to-seek drives the same
/// player these controls do, and the two affordances live in sibling sections.
/// The caller only shows this at all when `MeetingAudioPlayback.hasPlayableAudio`
/// found files on disk: purged or never-recorded audio gets nothing, not a
/// disabled control that would read as "playback is broken" instead of "there's
/// nothing to play" (see issue #14).
struct MeetingAudioPlayerView: View {
    let model: MeetingAudioPlayerModel

    @Environment(CaptureSession.self) private var session
    /// While the user is dragging the scrubber, the displayed time tracks the
    /// drag rather than the player's own periodic updates — otherwise a still-
    /// playing position observer fights the thumb the user is trying to move.
    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0

    var body: some View {
        Group {
            if model.loadError != nil {
                StatusLabel(.error, "Couldn't load this meeting's audio")
            } else {
                controls
            }
        }
        // The owner's meeting-keyed `.task` handles meeting switches, but a
        // retention purge while this meeting stays selected removes only *this*
        // view (`hasPlayableAudio` flips false the moment Settings clears
        // `audioDirectory`) — the detail neither disappears nor re-runs its
        // task, so without this hook the purged audio keeps playing with the
        // controls gone, and `isReady` keeps the transcript's seek affordances
        // alive. Captures this renderer's own `model` so a meeting switch
        // (which recreates this view via `.id`) can only ever tear down the
        // instance it was showing, never the owner's replacement; teardown is
        // idempotent, so overlapping with the owner's own calls is fine.
        .onDisappear { model.teardown() }
    }

    private var displayedTime: TimeInterval {
        isScrubbing ? scrubTime : model.currentTime
    }

    /// Recording in progress (`MeetingDetailView` pauses playback on that
    /// transition — never both at once, see #14 and #5) or the asset simply
    /// hasn't finished loading yet — either way, nothing here should be
    /// interactive. `model.play()` guards against the loading window
    /// independently, but disabling the controls is the visible half of that
    /// fix: without it, a tap in the gap between this view appearing and the
    /// owner's load finishing looked like it did nothing, not like it was
    /// refused.
    private var controlsDisabled: Bool {
        session.state != .idle || !model.isReady
    }

    private var controls: some View {
        HStack(spacing: Theme.Space.x3) {
            Button {
                model.isPlaying ? model.pause() : model.play()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.Colors.accent)
            .disabled(controlsDisabled)
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")

            Text(AudioTimeFormatting.string(from: displayedTime))
                .chText(.elapsedTimer)
                .foregroundStyle(Theme.Colors.textSecondary)
                .frame(minWidth: 40, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { displayedTime },
                    set: { newValue in
                        isScrubbing = true
                        scrubTime = newValue
                    }
                ),
                in: 0...max(model.duration, 0.01),
                onEditingChanged: { editing in
                    if !editing {
                        model.seek(to: scrubTime)
                        isScrubbing = false
                    }
                }
            )
            .tint(Theme.Colors.accent)
            .disabled(controlsDisabled)
            // Otherwise indistinguishable from the elapsed/duration text either
            // side of it to VoiceOver, which reads a bare `Slider` as a generic
            // value control with no indication of what it moves.
            .accessibilityLabel("Playback position")

            Text(AudioTimeFormatting.string(from: model.duration))
                .chText(.elapsedTimer)
                .foregroundStyle(Theme.Colors.textSecondary)
                .frame(minWidth: 40, alignment: .leading)
        }
    }
}
