import Foundation

/// Renders a playback position as `m:ss`, growing to `h:mm:ss` past an hour.
///
/// Its own type rather than a `Date`/`DateComponentsFormatter` call: those are
/// built for calendar durations, and a scrubber needs zero-padded seconds that
/// never drop a leading unit ("1:05", not "1:5" or "65 sec") at a size that fits
/// a transcript-line-height control.
public enum AudioTimeFormatting {
    /// `seconds` is clamped to zero rather than trusted — an `AVPlayer` briefly
    /// reports a negative or NaN position around a seek or before an asset has
    /// finished loading, and a scrubber label flashing "-0:01" reads as a bug
    /// rather than a rounding artifact.
    public static func string(from seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
