import Foundation

/// One line of the empty-state dashboard's rotating tip (#124) — quiet caption
/// copy, not a feature announcement. Each case names something real that's easy to
/// miss rather than something the app wants credit for.
public enum DashboardTip: CaseIterable, Equatable, Sendable {
    case headphones
    case enrollTeammates
    case transcriptReadyCallback
    case mcpSetup

    public var text: String {
        switch self {
        case .headphones:
            return "Headphones during a call keep your mic from picking up the other side twice."
        case .enrollTeammates:
            return
                "Enroll a teammate's voice in Settings → Participants and their lines come back under their name too."
        case .transcriptReadyCallback:
            return "Set a command in Settings → Callback and a finished transcript can hand itself straight to it."
        case .mcpSetup:
            return "Cheerio ships a small MCP server — Settings → Agents has what an agent needs to read your meetings."
        }
    }

    /// One tip, chosen deterministically from `seed` — pure so it's testable without
    /// touching however the caller actually seeds it (see `current`).
    ///
    /// The double modulo handles a negative `seed`: Swift's `%` keeps the sign of its
    /// left operand, so `seed % count` alone can land outside `0..<count` for a
    /// negative input, and this is meant to hold for any `Int`, not just the
    /// non-negative ones a real caller happens to pass.
    public static func forLaunch(seed: Int) -> DashboardTip {
        let all = allCases
        let index = ((seed % all.count) + all.count) % all.count
        return all[index]
    }

    /// Picked once per process, from a value that's the same for the life of the
    /// app and different across launches — "rotating per launch," not per render. A
    /// tip that changed on every `body` re-evaluation of a view that renders once
    /// and sits there would read as flicker, not rotation.
    public static let current: DashboardTip = forLaunch(seed: Int(ProcessInfo.processInfo.systemUptime * 1000))
}
