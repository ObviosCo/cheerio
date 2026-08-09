import CheerioKit
import SwiftUI

/// A readiness signal, not a recording one: whether the mic is hearing
/// anything right now, shown before and independently of pressing record. The
/// word "Recording" and the filled ring stay with `RecordingIndicator` — this
/// bar never claims that state on its own.
///
/// Fill is `Recording/Active` copper on a `Recording/Quiet` track: the same
/// pairing the token map reserves for exactly this — a "fill only" tone sized
/// to sit behind the same copper the recording indicator uses.
public struct LevelMeterView: View {
    private let level: AudioLevel

    public init(level: AudioLevel) {
        self.level = level
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Colors.recordingQuiet)
                Capsule()
                    .fill(Theme.Colors.recording)
                    .frame(width: proxy.size.width * CGFloat(level.meterFraction))
            }
        }
        .frame(height: 6)
        .chAnimation(Theme.Motion.fast, value: level)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone level")
        .accessibilityValue(level.meterFraction > 0.05 ? "Hearing you" : "Silent")
    }
}
