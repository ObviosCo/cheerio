import CheerioKit
import SwiftUI

/// The playback affordance for a meeting's retained audio.
///
/// Renders nothing at all when `MeetingAudioPlayback.hasPlayableAudio` says
/// there's nothing on disk — retention purged it, or it was never written —
/// rather than a disabled control, which would read as "playback is broken"
/// instead of "there's nothing to play" (see issue #14). `.id(meeting.persistentModelID)`
/// on the inner view forces SwiftUI to tear down and rebuild its player when the
/// sidebar selects a different meeting, instead of reusing one `@State` player
/// across two different meetings' audio.
struct MeetingAudioPlayerView: View {
    let meeting: Meeting

    var body: some View {
        let urls = MeetingAudioPlayback.channelFileURLs(for: meeting)
        if !urls.isEmpty {
            MeetingAudioPlayerControls(urls: urls)
                .id(meeting.persistentModelID)
        }
    }
}

private struct MeetingAudioPlayerControls: View {
    let urls: [URL]

    @Environment(CaptureSession.self) private var session
    @State private var model = MeetingAudioPlayerModel()
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
        .task { await model.load(urls: urls) }
        .onDisappear { model.teardown() }
        // Never both at once (see #14 and the mic-hears-your-speakers issue,
        // #5): a recording starting must actively pause audio that was already
        // playing, not just leave the button disabled from here on.
        .onChange(of: session.state) { _, newState in
            if newState != .idle { model.pause() }
        }
    }

    private var displayedTime: TimeInterval {
        isScrubbing ? scrubTime : model.currentTime
    }

    /// Recording in progress (see the `.onChange` above) or the asset simply
    /// hasn't finished loading yet — either way, nothing here should be
    /// interactive. `model.play()` guards against the loading window
    /// independently, but disabling the controls is the visible half of that
    /// fix: without it, a tap in the gap between this view appearing and its
    /// `.task` finishing looked like it did nothing, not like it was refused.
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
