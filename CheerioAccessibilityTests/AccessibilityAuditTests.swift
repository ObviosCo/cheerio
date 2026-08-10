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
/// that never selects a row.
///
/// The audit set is `.contrast` only, for now. The issue's shape is "start with
/// contrast; widen the audit set as the findings get manageable" — the other
/// macOS-supported checks (element descriptions, hit regions, element detection)
/// come with a triage pass first, so pre-existing findings become tracked issues
/// or justified exemptions instead of burying the one check that's non-negotiable.
/// Widen `auditTypes` as that triage lands.
// `XCUIApplication`'s API surface is main-actor isolated in this SDK; the class-level
// annotation is what keeps every helper's calls into it synchronous instead of
// scattering awaits (or warnings) through code that XCTest runs serially anyway.
@MainActor
final class AccessibilityAuditTests: XCTestCase {
    /// What every audit checks. See the type-level comment before widening.
    private static let auditTypes: XCUIAccessibilityAuditType = [.contrast]

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
    // name as its title, which is how it's told apart from the library behind it.

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

    /// Runs the audit over everything the app currently has on screen.
    ///
    /// No issue handler: nothing is exempted today, and that's the standard —
    /// a finding gets fixed, or it gets a handler entry here with a written
    /// justification and a tracking issue, the same bar as declining a review
    /// comment.
    private func audit(_ app: XCUIApplication) throws {
        try app.performAccessibilityAudit(for: Self.auditTypes)
    }

    private func auditSeededLibrary(appearance: Appearance, extraArguments: [String] = []) throws {
        let app = try launchSeeded(Self.libraryArguments + extraArguments, appearance: appearance)
        awaitWindow(of: app)
        try audit(app)
    }

    private func auditNoEnrollmentLibrary(appearance: Appearance) throws {
        let app = try launchNoEnrollment(Self.libraryArguments, appearance: appearance)
        awaitWindow(of: app)
        try audit(app)
    }

    private func auditSettings(tab: Int, titled title: String, appearance: Appearance) throws {
        let app = try launchSeeded(
            Self.libraryArguments + [
                "-screenshotOpenSettings", "YES",
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

    /// Skips rather than fails when the store isn't there: an unseeded machine is a
    /// setup problem, and reporting it as a contrast regression would teach people
    /// to ignore this check. The workflow seeds unconditionally, so CI never skips.
    private func requireStore(in home: String, seedHint: String) throws {
        let store = URL(filePath: home).appending(path: "Library/Application Support/co.obvios.cheerio.mac")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: store.path),
            """
            No seeded demo store at \(store.path).
            \(seedHint), or set CHEERIO_SCREENSHOT_HOME / CHEERIO_SCREENSHOT_HOME_NO_ENROLLMENT \
            (TEST_RUNNER_-prefixed for xcodebuild) to a home that has one. These tests audit a \
            store full of invented meetings; they never open yours.
            """
        )
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
    /// and the SwiftData store inside it — Foundation resolves the home directory
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
