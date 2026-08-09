import Foundation
import Testing

@testable import CheerioKit

/// `LaunchLocationClassifier` and `LaunchAdvisoryClassifier` together decide
/// whether issue #56's launch-time panel appears at all. Both are pure
/// functions over inputs a caller has already read, so every case below pins
/// the decision without touching the filesystem, quarantine attributes, or
/// AppKit — exactly the split issue #56 asks for.
@Suite struct LaunchLocationClassifierTests {
    @Test func derivedDataBuildIsNormal() {
        let path =
            "/Users/jax/Library/Developer/Xcode/DerivedData/Cheerio-abcdef/Build/Products/Debug/Cheerio.app"

        let location = LaunchLocationClassifier.classify(
            bundlePath: path, isQuarantined: false, isOnReadOnlyVolume: false
        )

        #expect(location == .normal)
    }

    @Test func installedApplicationsCopyIsNormal() {
        let location = LaunchLocationClassifier.classify(
            bundlePath: "/Applications/Cheerio.app", isQuarantined: false, isOnReadOnlyVolume: false
        )

        #expect(location == .normal)
    }

    @Test func appTranslocationPathIsDownloadedEvenWithoutTheQuarantineFlag() {
        // Translocation implies quarantine in practice, but the path alone is
        // what issue #56 calls out as the thing to check — the flag shouldn't
        // be load-bearing here.
        let path =
            "/private/var/folders/zz/zyxvpxvq6csfxvn_n0000000000000/T/AppTranslocation/D3ADB33F-0000-0000-0000-000000000000/d/Cheerio.app"

        let location = LaunchLocationClassifier.classify(
            bundlePath: path, isQuarantined: false, isOnReadOnlyVolume: false
        )

        #expect(location == .downloaded)
    }

    @Test func quarantinedDownloadsFolderCopyIsDownloadedEvenWithoutTranslocation() {
        // A build already approved once by Gatekeeper can run straight out of
        // ~/Downloads without a translocation path — but it still isn't
        // installed anywhere stable, and the quarantine attribute says so.
        let path = "/Users/jax/Downloads/Cheerio.app"

        let location = LaunchLocationClassifier.classify(
            bundlePath: path, isQuarantined: true, isOnReadOnlyVolume: false
        )

        #expect(location == .downloaded)
    }

    @Test func mountedDMGIsDMG() {
        let path = "/Volumes/Cheerio 26.8.9/Cheerio.app"

        let location = LaunchLocationClassifier.classify(
            bundlePath: path, isQuarantined: false, isOnReadOnlyVolume: true
        )

        #expect(location == .dmg)
    }

    @Test func writableVolumesPathIsNormal() {
        // A writable external drive can also mount under /Volumes; without the
        // read-only signal there's nothing distinguishing it from any other
        // stable path, so this must not read as a DMG.
        let path = "/Volumes/External SSD/Cheerio.app"

        let location = LaunchLocationClassifier.classify(
            bundlePath: path, isQuarantined: false, isOnReadOnlyVolume: false
        )

        #expect(location == .normal)
    }

    @Test func readOnlyVolumeOutsideVolumesIsNormal() {
        // The boot volume's Signed System Volume is read-only too; only the
        // /Volumes prefix distinguishes an actual DMG mount from that.
        let path = "/System/Applications/Cheerio.app"

        let location = LaunchLocationClassifier.classify(
            bundlePath: path, isQuarantined: false, isOnReadOnlyVolume: true
        )

        #expect(location == .normal)
    }

    @Test func quarantinedAndOnADMGReadsAsDownloadedNotDMG() {
        // The common real case: double-clicking straight off the mounted disk
        // image is usually both quarantined and (soon) translocated.
        // `.downloaded` wins the tie because it's checked first — the two
        // cases lead to the same advisory either way, so this is only about
        // which label the log line gets.
        let path = "/Volumes/Cheerio 26.8.9/Cheerio.app"

        let location = LaunchLocationClassifier.classify(
            bundlePath: path, isQuarantined: true, isOnReadOnlyVolume: true
        )

        #expect(location == .downloaded)
    }
}

@Suite struct LaunchAdvisoryClassifierTests {
    @Test func normalLocationIsAlwaysNone() {
        #expect(LaunchAdvisoryClassifier.advise(location: .normal, installedBundlePath: nil) == .none)
        #expect(
            LaunchAdvisoryClassifier.advise(location: .normal, installedBundlePath: "/Applications/Cheerio.app")
                == .none
        )
    }

    @Test func dmgWithNoInstalledCopyOffersToMove() {
        #expect(
            LaunchAdvisoryClassifier.advise(location: .dmg, installedBundlePath: nil)
                == .offerMoveToApplications
        )
    }

    @Test func downloadedWithNoInstalledCopyOffersToMove() {
        #expect(
            LaunchAdvisoryClassifier.advise(location: .downloaded, installedBundlePath: nil)
                == .offerMoveToApplications
        )
    }

    @Test func dmgWithAnInstalledCopyPointsAtIt() {
        #expect(
            LaunchAdvisoryClassifier.advise(location: .dmg, installedBundlePath: "/Applications/Cheerio.app")
                == .alreadyInstalled(installedBundlePath: "/Applications/Cheerio.app")
        )
    }

    @Test func downloadedWithAnInstalledCopyPointsAtIt() {
        #expect(
            LaunchAdvisoryClassifier.advise(
                location: .downloaded, installedBundlePath: "/Applications/Cheerio.app"
            )
                == .alreadyInstalled(installedBundlePath: "/Applications/Cheerio.app")
        )
    }
}
