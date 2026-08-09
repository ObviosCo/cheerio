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
            bundlePath: path, isQuarantined: false, isOnReadOnlyVolume: false, isInApplicationsDirectory: false
        )

        #expect(location == .normal)
    }

    @Test func installedApplicationsCopyIsNormal() {
        let location = LaunchLocationClassifier.classify(
            bundlePath: "/Applications/Cheerio.app", isQuarantined: false, isOnReadOnlyVolume: false,
            isInApplicationsDirectory: true
        )

        #expect(location == .normal)
    }

    @Test func quarantinedInstalledApplicationsCopyIsStillNormal() {
        // The bug this guards against: Finder-copying a bundle preserves
        // extended attributes, so a completely ordinary, Gatekeeper-approved
        // install can carry `com.apple.quarantine` indefinitely. Without the
        // `isInApplicationsDirectory` carve-out, this would misclassify as
        // `.downloaded`, and the one true installed copy would find *itself*
        // via `InstalledCopyLocator` and show the "already installed" panel
        // on every single launch.
        let location = LaunchLocationClassifier.classify(
            bundlePath: "/Applications/Cheerio.app", isQuarantined: true, isOnReadOnlyVolume: false,
            isInApplicationsDirectory: true
        )

        #expect(location == .normal)
    }

    @Test func quarantinedUserApplicationsCopyIsAlsoNormal() {
        // `~/Applications` is the other directory `InstalledCopyScan` treats
        // as stable — the carve-out has to cover it too, not just the
        // system-wide one.
        let location = LaunchLocationClassifier.classify(
            bundlePath: "/Users/jax/Applications/Cheerio.app", isQuarantined: true, isOnReadOnlyVolume: false,
            isInApplicationsDirectory: true
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
            bundlePath: path, isQuarantined: false, isOnReadOnlyVolume: false, isInApplicationsDirectory: false
        )

        #expect(location == .downloaded)
    }

    @Test func translocationStaysUnstableEvenIfFlaggedAsAnApplicationsDirectory() {
        // The carve-out added for the quarantine flag must not leak onto
        // translocation: issue #56's fix explicitly keeps "actual
        // translocation paths and DMG mounts unstable wherever they appear."
        // Passing `true` here can't happen for a real translocation path (it
        // never resolves under `/Applications`), but the classifier
        // shouldn't rely on that — it should ignore the flag for this case
        // entirely.
        let path =
            "/private/var/folders/zz/zyxvpxvq6csfxvn_n0000000000000/T/AppTranslocation/D3ADB33F-0000-0000-0000-000000000000/d/Cheerio.app"

        let location = LaunchLocationClassifier.classify(
            bundlePath: path, isQuarantined: false, isOnReadOnlyVolume: false, isInApplicationsDirectory: true
        )

        #expect(location == .downloaded)
    }

    @Test func quarantinedDownloadsFolderCopyIsDownloadedEvenWithoutTranslocation() {
        // A build already approved once by Gatekeeper can run straight out of
        // ~/Downloads without a translocation path — but it still isn't
        // installed anywhere stable, and the quarantine attribute says so.
        let path = "/Users/jax/Downloads/Cheerio.app"

        let location = LaunchLocationClassifier.classify(
            bundlePath: path, isQuarantined: true, isOnReadOnlyVolume: false, isInApplicationsDirectory: false
        )

        #expect(location == .downloaded)
    }

    @Test func mountedDMGIsDMG() {
        let path = "/Volumes/Cheerio 26.8.9/Cheerio.app"

        let location = LaunchLocationClassifier.classify(
            bundlePath: path, isQuarantined: false, isOnReadOnlyVolume: true, isInApplicationsDirectory: false
        )

        #expect(location == .dmg)
    }

    @Test func writableVolumesPathIsNormal() {
        // A writable external drive can also mount under /Volumes; without the
        // read-only signal there's nothing distinguishing it from any other
        // stable path, so this must not read as a DMG.
        let path = "/Volumes/External SSD/Cheerio.app"

        let location = LaunchLocationClassifier.classify(
            bundlePath: path, isQuarantined: false, isOnReadOnlyVolume: false, isInApplicationsDirectory: false
        )

        #expect(location == .normal)
    }

    @Test func readOnlyVolumeOutsideVolumesIsNormal() {
        // The boot volume's Signed System Volume is read-only too; only the
        // /Volumes prefix distinguishes an actual DMG mount from that.
        let path = "/System/Applications/Cheerio.app"

        let location = LaunchLocationClassifier.classify(
            bundlePath: path, isQuarantined: false, isOnReadOnlyVolume: true, isInApplicationsDirectory: false
        )

        #expect(location == .normal)
    }

    @Test func quarantinedAndOnADMGReadsAsDMGNotDownloaded() {
        // The common real case: double-clicking straight off the mounted disk
        // image is usually both quarantined and (soon) translocated. `.dmg` is
        // checked ahead of the quarantine flag — the two cases lead to the
        // same advisory either way, so this is only about which label the log
        // line gets.
        let path = "/Volumes/Cheerio 26.8.9/Cheerio.app"

        let location = LaunchLocationClassifier.classify(
            bundlePath: path, isQuarantined: true, isOnReadOnlyVolume: true, isInApplicationsDirectory: false
        )

        #expect(location == .dmg)
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

    @Test func quarantinedInstalledCopyNeverTargetsItselfWithThePanel() {
        // End-to-end version of `quarantinedInstalledApplicationsCopyIsStillNormal`:
        // classify the installed copy's own launch, then feed that straight
        // into `advise` the way `LaunchLocationCheck` does, using the
        // installed copy's own path as `installedBundlePath` — exactly what
        // `InstalledCopyScan.find()` would return for a launch that finds
        // itself. The panel must not appear.
        let installedPath = "/Applications/Cheerio.app"
        let location = LaunchLocationClassifier.classify(
            bundlePath: installedPath, isQuarantined: true, isOnReadOnlyVolume: false,
            isInApplicationsDirectory: true
        )

        let advisory = LaunchAdvisoryClassifier.advise(location: location, installedBundlePath: installedPath)

        #expect(advisory == .none)
    }
}

/// `CheerioKit.InstalledCopyLocator`'s matching and tie-breaking rule, tested
/// against plain `Candidate` data rather than a real `/Applications` — the
/// directory listing and `Bundle(url:)` reads that produce that data are
/// `InstalledCopyScan`'s job, in the app target, where they can't be run
/// under Swift Testing without a real disk.
@Suite struct InstalledCopyLocatorTests {
    private typealias Candidate = InstalledCopyLocator.Candidate

    @Test func noCandidatesIsNil() {
        let path = InstalledCopyLocator.find(
            among: [], acceptableBundleIdentifiers: ["app.cheerio.mac"], preferredName: "Cheerio.app"
        )

        #expect(path == nil)
    }

    @Test func noMatchingIdentifierIsNil() {
        let candidates = [Candidate(path: "/Applications/NotCheerio.app", bundleIdentifier: "com.example.other")]

        let path = InstalledCopyLocator.find(
            among: candidates, acceptableBundleIdentifiers: ["app.cheerio.mac"], preferredName: "Cheerio.app"
        )

        #expect(path == nil)
    }

    @Test func unreadableCandidateNeverMatches() {
        // A candidate whose Info.plist couldn't be read carries a `nil`
        // identifier — it must not accidentally match a search for `nil`
        // bundle identifiers (there is no such search) or crash the filter.
        let candidates = [Candidate(path: "/Applications/Unreadable.app", bundleIdentifier: nil)]

        let path = InstalledCopyLocator.find(
            among: candidates, acceptableBundleIdentifiers: ["app.cheerio.mac"], preferredName: "Cheerio.app"
        )

        #expect(path == nil)
    }

    @Test func renamedInstalledCopyStillMatchesByIdentifier() {
        // The bug this guards against: a locator that only checked for a
        // same-named file at a fixed path would miss this and offer to
        // create a second copy right next to it.
        let candidates = [Candidate(path: "/Applications/Cheerio 2.app", bundleIdentifier: "app.cheerio.mac")]

        let path = InstalledCopyLocator.find(
            among: candidates, acceptableBundleIdentifiers: ["app.cheerio.mac"], preferredName: "Cheerio.app"
        )

        #expect(path == "/Applications/Cheerio 2.app")
    }

    @Test func exactNameMatchIsPreferredAmongSeveralIdentifierMatches() {
        // A renamed leftover copy alongside the real one — both carry the
        // right identifier, but only one is named the way the running
        // bundle is, and that's the one a user would expect "Cheerio Is
        // Already Installed" to mean.
        let candidates = [
            Candidate(path: "/Applications/Cheerio (old).app", bundleIdentifier: "app.cheerio.mac"),
            Candidate(path: "/Applications/Cheerio.app", bundleIdentifier: "app.cheerio.mac"),
        ]

        let path = InstalledCopyLocator.find(
            among: candidates, acceptableBundleIdentifiers: ["app.cheerio.mac"], preferredName: "Cheerio.app"
        )

        #expect(path == "/Applications/Cheerio.app")
    }

    @Test func firstMatchWinsWhenNoneIsAnExactNameMatch() {
        let candidates = [
            Candidate(path: "/Applications/Cheerio (old).app", bundleIdentifier: "app.cheerio.mac"),
            Candidate(path: "/Users/jax/Applications/Cheerio (older).app", bundleIdentifier: "app.cheerio.mac"),
        ]

        let path = InstalledCopyLocator.find(
            among: candidates, acceptableBundleIdentifiers: ["app.cheerio.mac"], preferredName: "Cheerio.app"
        )

        #expect(path == "/Applications/Cheerio (old).app")
    }

    /// The `co.obvios` rename (#22): a build carrying the *new* identifier,
    /// launched from a DMG, still has to recognize an installed copy that
    /// hasn't been relaunched since the rename and so still reports the old
    /// one. Without this, `LaunchAdvisoryClassifier` would offer to move to
    /// `/Applications`, and that move would fail — the path is already taken
    /// by the very copy this search should have found.
    @Test func matchesAnInstalledCopyStillCarryingTheLegacyIdentifier() {
        let candidates = [Candidate(path: "/Applications/Cheerio.app", bundleIdentifier: "app.cheerio.mac")]

        let path = InstalledCopyLocator.find(
            among: candidates,
            acceptableBundleIdentifiers: ["co.obvios.cheerio.mac", "app.cheerio.mac"],
            preferredName: "Cheerio.app"
        )

        #expect(path == "/Applications/Cheerio.app")
    }

    @Test func canonicalIdentifierAlsoAcceptsTheLegacyOne() {
        let identifiers = InstalledCopyLocator.acceptableBundleIdentifiers(
            runningAs: "co.obvios.cheerio.mac", legacyBundleIdentifier: "app.cheerio.mac"
        )

        #expect(identifiers == ["co.obvios.cheerio.mac", "app.cheerio.mac"])
    }

    /// The fork-correctness fix: a fork built under its own identifier must not
    /// get the legacy identifier added to its acceptable set. It never shipped
    /// under `app.cheerio.mac`, so an unrelated app that happens to use that
    /// identifier is not "itself, already installed."
    @Test func forkIdentifierMatchesOnlyItself() {
        let identifiers = InstalledCopyLocator.acceptableBundleIdentifiers(
            runningAs: "com.example.myfork.cheerio", legacyBundleIdentifier: "app.cheerio.mac"
        )

        #expect(identifiers == ["com.example.myfork.cheerio"])
    }

    /// End-to-end version of the bug the fix addresses: a fork's own
    /// `InstalledCopyScan.find()` composes `acceptableBundleIdentifiers(runningAs:)`
    /// with `find(among:acceptableBundleIdentifiers:preferredName:)` exactly this
    /// way. Without the gate, this would return the legacy candidate's path — the
    /// fork would treat an unrelated, independently-installed `app.cheerio.mac`
    /// copy as itself, hand off to it, and quit.
    @Test func aForksScanNeverMatchesAnUnrelatedLegacyInstall() {
        let candidates = [Candidate(path: "/Applications/Cheerio.app", bundleIdentifier: "app.cheerio.mac")]
        let forkIdentifiers = InstalledCopyLocator.acceptableBundleIdentifiers(
            runningAs: "com.example.myfork.cheerio", legacyBundleIdentifier: "app.cheerio.mac"
        )

        let path = InstalledCopyLocator.find(
            among: candidates, acceptableBundleIdentifiers: forkIdentifiers, preferredName: "Cheerio.app"
        )

        #expect(path == nil)
    }

    /// The two-edit fork configuration README.md documents, exercised exactly as
    /// `InstalledCopyScan.find()` would compose it: a fork's `Bundle.main.bundleIdentifier`
    /// and its (README-instructed) `AudioStorage.appBundleIdentifier` are the same
    /// custom string by construction, since the fork changed the latter to match the
    /// former. That equality is exactly what made the pre-fix gate self-defeating —
    /// comparing against `appBundleIdentifier` would have made this `true`. Comparing
    /// against the separate, fixed `officialBundleIdentifier` instead means the
    /// legacy match stays off regardless.
    @Test func aCorrectlyConfiguredForkStillGetsNoLegacyMatch() {
        let forksRuntimeIdentifier = "com.example.myfork.cheerio"
        // Stands in for the fork's own `AudioStorage.appBundleIdentifier`, changed
        // per README.md to equal `forksRuntimeIdentifier` — deliberately the
        // identical string, not a distractor.
        let forksAppBundleIdentifier = forksRuntimeIdentifier
        let candidates = [Candidate(path: "/Applications/Cheerio.app", bundleIdentifier: "app.cheerio.mac")]

        let forkIdentifiers = InstalledCopyLocator.acceptableBundleIdentifiers(
            runningAs: forksRuntimeIdentifier, legacyBundleIdentifier: "app.cheerio.mac"
        )
        let path = InstalledCopyLocator.find(
            among: candidates, acceptableBundleIdentifiers: forkIdentifiers, preferredName: "Cheerio.app"
        )

        #expect(forksAppBundleIdentifier == forksRuntimeIdentifier)
        #expect(path == nil)
    }
}
