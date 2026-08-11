import XCTest

/// Audits the app's screens for accessibility regressions — contrast first — so a
/// dark-text-on-dark-fill mistake fails a PR check instead of reaching a human
/// (issue #142; #141 is the regression class this exists to catch).
///
/// This is a sibling of `CheerioScreenshotTests`, not part of it, and the split is
/// the point: screenshots are capture-and-continue — a surface that fails to
/// photograph must not cost the reviewer the ones that worked — while an audit is
/// pass/fail, and a red audit must not stop screenshots from being captured. Two
/// bundles with two schemes (`CheerioAccessibility` here) keep those semantics
/// structural: `.github/workflows/accessibility.yml` runs this one and turns any
/// finding into a failed check, and the screenshots scheme can't pick these tests
/// up by accident.
///
/// Everything else is shared with the screenshot harness, deliberately: the same
/// seeded demo store (`Scripts/screenshots/seed-store.sh`), the same scratch home
/// via `CFFIXED_USER_HOME`, and the same `ScreenshotMode` launch arguments to reach
/// each state without clicking. Every surface is audited twice — light and dark —
/// through `-screenshotAppearance`, because a contrast failure usually lives in
/// exactly one appearance.
///
/// The library audits pass `-screenshotSelectMeeting`, so the *selected* row state
/// is on screen — #141 shipped precisely because selection is invisible to anything
/// that never selects a row — and the selected row is audited both with the window
/// key (`Accent/Selection`) and without it (`Accent/SelectionInactive`), since
/// `chListRowSelection` draws a different fill for each.
///
/// ## What a finding means, and what gets suppressed
///
/// The audit set is `.contrast` only, for now. The issue's shape is "start with
/// contrast; widen the audit set as the findings get manageable" — the other
/// macOS-supported checks (element descriptions, hit regions, element detection)
/// come with a triage pass first, so pre-existing findings become tracked issues
/// or justified exemptions instead of burying the one check that's non-negotiable.
///
/// Findings pass through one filter, ``shouldSuppress(_:)``, and the bar for a rule
/// there is the bar #142 sets for any exemption: a written justification, grounded
/// in measurement. The first CI run (PR #158) produced 159 contrast findings whose
/// attached element screenshots were measured pixel-by-pixel afterwards: the real
/// ones were all one class (system `.secondary`/`.tertiary` text measuring
/// 2.7–4.3:1, since fixed by moving every text style onto the design tokens), and
/// the rest were artifacts of *where* the audit sampled, not of any color in the
/// app — elements occluded by an overlapping
/// window, rows clipped by a scroll viewport, and small-glyph antialiasing on the
/// runner's 1x display flagging text whose rendered pixels measure 5.9:1 and up
/// (one flagged element measured 17.3:1). The filter re-measures exactly what the
/// audit claims: the element's rendered pixels, from its own screenshot. Nothing
/// is suppressed by name, screen, or appearance — a real regression on those same
/// elements still measures below AA and still fails.
@MainActor
final class AccessibilityAuditTests: XCTestCase {
    /// What every audit checks. See the type-level comment before widening.
    private static let auditTypes: XCUIAccessibilityAuditType = [.contrast]

    /// The WCAG AA ratio for normal text, which is also what the audit enforces.
    /// Applied uniformly — large text is allowed 3:1, so re-measuring against 4.5
    /// never suppresses something the audit would hold to a stricter bar.
    private static let aaContrast = 4.5

    /// Where the workflow seeded the demo store, as a home directory. Same contract
    /// as `CheerioScreenshotTests`: `TEST_RUNNER_CHEERIO_SCREENSHOT_HOME` reaches
    /// this process with the prefix stripped, and the constant is the fallback that
    /// keeps the two halves from drifting apart silently.
    private static let defaultSeededHome = "/tmp/cheerio-screenshots-home"

    /// The second seeded store — meetings, nobody enrolled — so the dashboard with
    /// issue #125's voice-enrollment prompt on it gets audited too, not just
    /// photographed.
    private static let defaultNoEnrollmentHome = "/tmp/cheerio-screenshots-home-no-enrollment"

    /// How long to wait for a window to appear. Generous because the first launch of
    /// the run pays for the model container opening on a cold runner.
    private static let windowTimeout: TimeInterval = 60

    /// Time to let a window finish arriving after it exists —
    /// `ScreenshotMode.applyAtLaunch` deliberately resizes and re-fronts windows up
    /// to ~1.1s after first render, and an audit of a window mid-move is an audit
    /// of the wrong pixels.
    private static let settle: TimeInterval = 3

    /// Launch arguments every audit passes: no update checks, no first-run
    /// walkthrough, and the same fixed window size the screenshots use, so the two
    /// harnesses look at the same layout.
    private static let libraryArguments = [
        "-SUEnableAutomaticChecks", "NO",
        "-SUAutomaticallyUpdate", "NO",
        "-onboardingHasCompleted", "YES",
        "-screenshotWindowSize", "1440x900",
    ]

    /// The two appearances every surface is audited under, as the
    /// `-screenshotAppearance` values `ScreenshotMode` reads.
    private enum Appearance: String {
        case light
        case dark
    }

    /// Missing seeded store, in an environment that demanded one.
    private struct MissingSeededStore: Error, CustomStringConvertible {
        let description: String
    }

    private var app: XCUIApplication?

    override func setUp() {
        // Every audit issue on a surface is worth hearing about in one run, not one
        // per push — an audit failure doesn't invalidate the rest of the test the
        // way a missing window would.
        continueAfterFailure = true
    }

    // The async override rather than the plain one: `tearDown()` is a nonisolated
    // requirement, so a synchronous body can't touch the main-actor state above —
    // this one hops instead.
    override func tearDown() async throws {
        await MainActor.run {
            app?.terminate()
            app = nil
        }
    }

    // MARK: - Library

    /// The library with a meeting selected — the selected-row state, specifically,
    /// because #141 (dark title on the dark selection fill) only exists on a row
    /// that *is* selected. The fix is `chListRowSelection`; this is what keeps it
    /// fixed.
    func testLibrarySelectedRowLight() throws {
        try auditSeededLibrary(appearance: .light, extraArguments: ["-screenshotSelectMeeting", "1"])
    }

    func testLibrarySelectedRowDark() throws {
        try auditSeededLibrary(appearance: .dark, extraArguments: ["-screenshotSelectMeeting", "1"])
    }

    /// The same selected row while the window doesn't appear active —
    /// `chListRowSelection` swaps to `Accent/SelectionInactive` for that, and #141's
    /// bar was explicit that both fills have to hold their text pairings.
    func testLibrarySelectedRowInactiveLight() throws {
        try auditSelectedRowInactive(appearance: .light)
    }

    func testLibrarySelectedRowInactiveDark() throws {
        try auditSelectedRowInactive(appearance: .dark)
    }

    /// The detail pane with the transcript disclosure open — speaker names, chips,
    /// timestamps, all the text the collapsed default hides.
    func testLibraryTranscriptLight() throws {
        try auditSeededLibrary(
            appearance: .light,
            extraArguments: ["-screenshotSelectMeeting", "2", "-screenshotExpandTranscript", "YES"]
        )
    }

    func testLibraryTranscriptDark() throws {
        try auditSeededLibrary(
            appearance: .dark,
            extraArguments: ["-screenshotSelectMeeting", "2", "-screenshotExpandTranscript", "YES"]
        )
    }

    /// Nothing selected: the empty-state dashboard (#124).
    func testLibraryEmptyStateLight() throws {
        try auditSeededLibrary(appearance: .light)
    }

    func testLibraryEmptyStateDark() throws {
        try auditSeededLibrary(appearance: .dark)
    }

    /// The same dashboard with issue #125's voice-enrollment prompt on it, which
    /// only renders when the store has meetings but no enrolled voices.
    func testLibraryEmptyStateNoEnrollmentLight() throws {
        try auditNoEnrollmentLibrary(appearance: .light)
    }

    func testLibraryEmptyStateNoEnrollmentDark() throws {
        try auditNoEnrollmentLibrary(appearance: .dark)
    }

    // MARK: - Settings

    // Tab indices are the order of `SettingsView`'s TabView, opened via the same
    // launch arguments the screenshots use; the window takes the selected tab's
    // name as its title, which is how it's told apart from any other window.

    func testSettingsGeneralLight() throws { try auditSettings(tab: 0, titled: "General", appearance: .light) }
    func testSettingsGeneralDark() throws { try auditSettings(tab: 0, titled: "General", appearance: .dark) }

    func testSettingsPrivacyLight() throws { try auditSettings(tab: 1, titled: "Privacy", appearance: .light) }
    func testSettingsPrivacyDark() throws { try auditSettings(tab: 1, titled: "Privacy", appearance: .dark) }

    func testSettingsParticipantsLight() throws {
        try auditSettings(tab: 2, titled: "Participants", appearance: .light)
    }

    func testSettingsParticipantsDark() throws {
        try auditSettings(tab: 2, titled: "Participants", appearance: .dark)
    }

    func testSettingsUpdatesLight() throws { try auditSettings(tab: 3, titled: "Updates", appearance: .light) }
    func testSettingsUpdatesDark() throws { try auditSettings(tab: 3, titled: "Updates", appearance: .dark) }

    func testSettingsCallbackLight() throws { try auditSettings(tab: 4, titled: "Callback", appearance: .light) }
    func testSettingsCallbackDark() throws { try auditSettings(tab: 4, titled: "Callback", appearance: .dark) }

    func testSettingsAgentsLight() throws { try auditSettings(tab: 5, titled: "Agents", appearance: .light) }
    func testSettingsAgentsDark() throws { try auditSettings(tab: 5, titled: "Agents", appearance: .dark) }

    // MARK: - Onboarding

    /// The walkthrough's first step, reached the way a real first run reaches it:
    /// an empty home with the completed flag off. One step rather than all seven —
    /// the walkthrough steps share `OnboardingScaffold`'s text styles, so the
    /// welcome step stands in for the set until there's a reason to widen.
    func testOnboardingWelcomeLight() throws { try auditOnboardingWelcome(appearance: .light) }
    func testOnboardingWelcomeDark() throws { try auditOnboardingWelcome(appearance: .dark) }

    // MARK: - Audits

    /// Runs the audit over everything the app currently has on screen, filtering
    /// each finding through ``shouldSuppress(_:)`` — see the type-level comment for
    /// the standard a suppression rule has to meet.
    private func audit(_ app: XCUIApplication) throws {
        try app.performAccessibilityAudit(for: Self.auditTypes) { issue in
            self.shouldSuppress(issue)
        }
    }

    private func auditSeededLibrary(appearance: Appearance, extraArguments: [String] = []) throws {
        let app = try launchSeeded(Self.libraryArguments + extraArguments, appearance: appearance)
        awaitWindow(of: app)
        try audit(app)
    }

    /// Selection with the window *not* key. Handing activation to another app —
    /// Finder is always running and puts no window of its own over ours — flips
    /// `\.appearsActive` for the whole app without covering a single pixel of it,
    /// which an overlapping window of our own could never guarantee on the
    /// runner's 1024×768 screen.
    private func auditSelectedRowInactive(appearance: Appearance) throws {
        let app = try launchSeeded(
            Self.libraryArguments + ["-screenshotSelectMeeting", "1"],
            appearance: appearance
        )
        awaitWindow(of: app)
        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        Thread.sleep(forTimeInterval: 1)
        try audit(app)
    }

    private func auditSettings(tab: Int, titled title: String, appearance: Appearance) throws {
        // `-screenshotCloseMainWindow` because this audit is *of Settings*: the
        // library window can't help but sit underneath it on a small CI display,
        // and an audit walks every window — leaving the library up would re-audit
        // its text through the Settings window's pixels. The library gets its own
        // audits above, unoccluded.
        let app = try launchSeeded(
            Self.libraryArguments + [
                "-screenshotOpenSettings", "YES",
                "-screenshotCloseMainWindow", "YES",
                "-com_apple_SwiftUI_Settings_selectedTabIndex", String(tab),
            ],
            appearance: appearance
        )
        let window = app.windows[title]
        XCTAssertTrue(
            window.waitForExistence(timeout: Self.windowTimeout),
            "No window titled “\(title)” — the app opened \(app.windows.count) window(s)."
        )
        Thread.sleep(forTimeInterval: Self.settle)
        try audit(app)
    }

    private func auditOnboardingWelcome(appearance: Appearance) throws {
        let app = launch(
            home: try freshHome(),
            arguments: [
                "-SUEnableAutomaticChecks", "NO",
                "-SUAutomaticallyUpdate", "NO",
                "-onboardingHasCompleted", "NO",
                "-screenshotAppearance", appearance.rawValue,
            ]
        )
        // The walkthrough's own content, not just "some window" — the library window
        // can legitimately open first and hand off (#63), and auditing mid-handoff
        // audits a window that's about to close.
        let getStarted = app.buttons["Get Started"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: Self.windowTimeout), "The walkthrough never appeared.")
        XCTAssertTrue(
            app.windows["Cheerio"].waitForNonExistence(timeout: Self.windowTimeout),
            "The library window opened but never handed off to the walkthrough."
        )
        Thread.sleep(forTimeInterval: Self.settle)
        try audit(app)
    }

    // MARK: - Suppression

    /// Whether a finding is one of the audit's known measurement artifacts rather
    /// than a color problem in the app. Everything here re-checks evidence about
    /// *this* element at *this* moment — no rule matches on name, screen, or
    /// appearance, so a genuine regression on a suppressed element's twin still
    /// fails.
    ///
    /// Two rules, both grounded in the first run's measured findings (see the
    /// type-level comment):
    ///
    /// 1. **The element isn't where the audit sampled.** An element scrolled out of
    ///    its viewport, or whose accessibility frame misses its rendered glyphs
    ///    (a baseline-aligned bullet reports a frame the glyph isn't in), samples a
    ///    slice of background — or of whatever text happens to sit next to it — and
    ///    the resulting ratio describes pixels the element didn't draw. Not being
    ///    hittable at its own hit point, or rendering as one flat color, is that
    ///    case. The flat-region rule's known blind spot is text drawn in *exactly*
    ///    its background's color — pixels can't see what was never rendered — but
    ///    that requires equality, not just poor contrast: #141's dark-on-dark still
    ///    renders two clusters and still fails.
    ///
    /// 2. **The rendered pixels prove AA.** On the runner's 1x display the audit
    ///    flags small text whose core glyph pixels measure well past 4.5:1 — the
    ///    first run flagged one element at a measured 17.3:1 — because antialiased
    ///    edge pixels dominate a small glyph's coverage. Re-measuring the element's
    ///    own screenshot, foreground cluster against background cluster, and
    ///    suppressing only at ≥ 4.5:1 keeps the check anchored to what WCAG
    ///    actually asks of the colors on screen.
    private func shouldSuppress(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        guard let element = issue.element, element.exists else { return false }
        if !element.isHittable { return true }
        guard let measured = Self.measuredContrast(of: element) else { return false }
        // Flat region: nothing distinguishable was rendered inside the frame the
        // audit measured — rule 1's second half.
        if measured < 1.1 { return true }
        return measured >= Self.aaContrast
    }

    /// The element's rendered contrast, measured from its own screenshot: the most
    /// frequent color is the background, and the most contrasting color that still
    /// covers a meaningful share of pixels (≥ 0.5%, floor 3 — below that it's an
    /// antialiasing remnant, not a glyph) is the foreground.
    private static func measuredContrast(of element: XCUIElement) -> Double? {
        let image = element.screenshot().image
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var counts: [UInt32: Int] = [:]
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let key =
                UInt32(pixels[offset]) << 16 | UInt32(pixels[offset + 1]) << 8 | UInt32(pixels[offset + 2])
            counts[key, default: 0] += 1
        }
        guard let background = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        let significant = max(3, (width * height) / 200)
        let backgroundLuminance = luminance(background)
        var best = 1.0
        for (color, count) in counts where count >= significant {
            let l = luminance(color)
            let ratio =
                (max(l, backgroundLuminance) + 0.05) / (min(l, backgroundLuminance) + 0.05)
            if ratio > best { best = ratio }
        }
        return best
    }

    /// WCAG 2.1 relative luminance of a packed sRGB pixel.
    private static func luminance(_ packed: UInt32) -> Double {
        func linear(_ channel: UInt32) -> Double {
            let c = Double(channel) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear((packed >> 16) & 0xFF)
            + 0.7152 * linear((packed >> 8) & 0xFF)
            + 0.0722 * linear(packed & 0xFF)
    }

    // MARK: - Launching

    /// Launches against the demo store the workflow seeded.
    private func launchSeeded(_ arguments: [String], appearance: Appearance) throws -> XCUIApplication {
        let home = ProcessInfo.processInfo.environment["CHEERIO_SCREENSHOT_HOME"] ?? Self.defaultSeededHome
        try requireStore(in: home, seedHint: "Run `Scripts/screenshots/seed-store.sh` first")
        return launch(
            home: URL(filePath: home),
            arguments: arguments + ["-screenshotAppearance", appearance.rawValue]
        )
    }

    /// Launches against the second seeded store — meetings, nobody enrolled.
    private func launchNoEnrollment(_ arguments: [String], appearance: Appearance) throws -> XCUIApplication {
        let home =
            ProcessInfo.processInfo.environment["CHEERIO_SCREENSHOT_HOME_NO_ENROLLMENT"]
            ?? Self.defaultNoEnrollmentHome
        try requireStore(
            in: home,
            seedHint: "Run `Scripts/screenshots/seed-store.sh --home \(home) --skip-enrollment` first"
        )
        return launch(
            home: URL(filePath: home),
            arguments: arguments + ["-screenshotAppearance", appearance.rawValue]
        )
    }

    private func auditNoEnrollmentLibrary(appearance: Appearance) throws {
        let app = try launchNoEnrollment(Self.libraryArguments, appearance: appearance)
        awaitWindow(of: app)
        try audit(app)
    }

    /// On a developer's machine a missing store skips, with instructions — an
    /// unseeded checkout is a setup problem, and reporting it as a contrast
    /// regression teaches people to ignore the check. In CI it *fails*: the
    /// workflow seeds unconditionally and sets `CHEERIO_REQUIRE_SEEDED_STORE`, so a
    /// store missing there means the seeder or the env plumbing broke — and a
    /// required check that greens by skipping every fixture-dependent test would
    /// be worse than red.
    private func requireStore(in home: String, seedHint: String) throws {
        let store = URL(filePath: home).appending(path: "Library/Application Support/co.obvios.cheerio.mac")
        guard !FileManager.default.fileExists(atPath: store.path) else { return }
        let message = """
            No seeded demo store at \(store.path).
            \(seedHint), or set CHEERIO_SCREENSHOT_HOME / CHEERIO_SCREENSHOT_HOME_NO_ENROLLMENT \
            (TEST_RUNNER_-prefixed for xcodebuild) to a home that has one. These tests audit a \
            store full of invented meetings; they never open yours.
            """
        if ProcessInfo.processInfo.environment["CHEERIO_REQUIRE_SEEDED_STORE"] != nil {
            throw MissingSeededStore(description: message)
        }
        throw XCTSkip(message)
    }

    /// An empty home, for the audits that have to look like a first run.
    private func freshHome() throws -> URL {
        let home = URL(filePath: NSTemporaryDirectory())
            .appending(path: "cheerio-accessibility-fresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    /// `CFFIXED_USER_HOME` is what actually relocates `~/Library/Application Support`
    /// and the SwiftData store inside it: Foundation resolves the home directory
    /// through CoreFoundation, which reads that variable and ignores `HOME`. `HOME`
    /// is set as well, for anything that shells out.
    private func launch(home: URL, arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CFFIXED_USER_HOME"] = home.path
        app.launchEnvironment["HOME"] = home.path
        app.launchArguments = arguments
        app.launch()
        self.app = app
        return app
    }

    /// Waits for the app's one window, then lets `ScreenshotMode.applyAtLaunch`
    /// finish moving it.
    private func awaitWindow(of app: XCUIApplication) {
        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: Self.windowTimeout),
            "The app never opened a window."
        )
        Thread.sleep(forTimeInterval: Self.settle)
    }
}
