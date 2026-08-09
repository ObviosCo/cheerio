import Foundation
import Testing

@testable import CheerioKit

/// The empty-state dashboard's rotating tip (#124) is a pure function of a seed —
/// everything about *how* the seed varies across launches lives in
/// `DashboardTip.current`, which this suite deliberately doesn't touch.
@Suite struct DashboardTipTests {
    @Test func sameSeedAlwaysPicksTheSameTip() {
        #expect(DashboardTip.forLaunch(seed: 7) == DashboardTip.forLaunch(seed: 7))
    }

    @Test func aFullSeedCycleVisitsEveryTipExactlyOnce() {
        let count = DashboardTip.allCases.count
        let picked = (0..<count).map { DashboardTip.forLaunch(seed: $0) }
        #expect(Set(picked).count == count)
    }

    @Test func negativeSeedsStillResolveToAValidTip() {
        // A real caller only ever passes a non-negative seed, but the function takes
        // a bare `Int` and shouldn't crash or fall outside `allCases` for one that
        // isn't.
        for seed in [-1, -DashboardTip.allCases.count, Int.min] {
            #expect(DashboardTip.allCases.contains(DashboardTip.forLaunch(seed: seed)))
        }
    }

    @Test func everyTipHasNonEmptyText() {
        for tip in DashboardTip.allCases {
            #expect(!tip.text.isEmpty)
        }
    }
}
