import XCTest

/// Photographs the app's screens from inside `xcodebuild test`, for the PR previews
/// `.github/workflows/screenshots.yml` posts.
///
/// This is the CI half of the screenshot harness. `Scripts/screenshots/capture.sh` is
/// the local half, and the two share everything that matters: the same seeded demo
/// store (`Scripts/screenshots/seed-store.sh`) and the same `ScreenshotMode` launch
/// arguments in the app target. Only the shutter differs — the script shoots windows
/// with `screencapture -l`, which needs Screen Recording granted to whoever invoked
/// it, and a GitHub runner has nobody to grant it. A UI test's own screenshot API
/// isn't reaching into another process's window the way `screencapture` is, so it
/// isn't gated the same way, which is the whole reason this target exists.
///
/// Two app configurations run in this one bundle:
///
/// - the **seeded** one, launched against the demo store the workflow seeded before
///   the test run — the library and Settings shots need meetings on screen;
/// - the **fresh** one, launched against an empty scratch home with the walkthrough's
///   completed flag explicitly off, which is what a genuine first run looks like.
///
/// Test methods don't depend on each other or on their order: the walkthrough's
/// completed flag is passed as a launch argument every time (the *argument* domain,
/// which is read-only and dies with the process) rather than left to whatever
/// `cfprefsd` is holding, because preferences resolve by uid and so ignore the
/// scratch home entirely.
final class ScreenshotCaptureTests: XCTestCase {
    /// Where the workflow seeded the demo store, as a home directory — i.e. the
    /// parent of `Library/Application Support/app.cheerio.mac`.
    ///
    /// `Scripts/screenshots/seed-store.sh` writes here by default and the workflow
    /// also passes it as `TEST_RUNNER_CHEERIO_SCREENSHOT_HOME` (xcodebuild forwards
    /// `TEST_RUNNER_`-prefixed variables to the test runner with the prefix
    /// stripped). The constant is the fallback so the two halves can't drift apart
    /// silently if that forwarding ever stops working.
    private static let defaultSeededHome = "/tmp/cheerio-screenshots-home"

    /// How long to wait for a window to appear. Generous because the first launch of
    /// the run pays for the model container opening on a cold runner.
    private static let windowTimeout: TimeInterval = 60

    /// Time to let a window finish arriving after it exists.
    ///
    /// `ScreenshotMode.applyAtLaunch` deliberately waits ~700ms before resizing (macOS
    /// restores the remembered frame after the first render) and another ~400ms before
    /// bringing a secondary window to the front, so a screenshot taken the instant a
    /// window exists catches the app mid-move. There's nothing observable to wait on
    /// for either, hence a sleep on this side too.
    private static let settle: TimeInterval = 3

    /// Launch arguments every shot passes: no update checks, no first-run walkthrough,
    /// and a fixed window size so two runs are diffable by eye.
    private static let libraryArguments = [
        "-SUEnableAutomaticChecks", "NO",
        "-SUAutomaticallyUpdate", "NO",
        "-onboardingHasCompleted", "YES",
        "-screenshotWindowSize", "1440x900",
    ]

    private var app: XCUIApplication?

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
        app = nil
    }

    // MARK: - Library

    func testLibrary() throws {
        let app = try launchSeeded(Self.libraryArguments + ["-screenshotSelectMeeting", "1"])
        capture(soleWindow(of: app), named: "library")
    }

    func testLibraryTranscript() throws {
        let app = try launchSeeded(Self.libraryArguments + ["-screenshotSelectMeeting", "2"])
        capture(soleWindow(of: app), named: "library-transcript")
    }

    // MARK: - Settings

    // Tab indices are the order of `SettingsView`'s TabView. SwiftUI keeps the
    // selection in this default, so passing it as a launch argument opens the tab
    // without a click — and the Settings window takes the selected tab's name as its
    // title, which is also how it's told apart from the library window behind it.

    func testSettingsGeneral() throws {
        try captureSettings(tab: 0, titled: "General", named: "settings-general")
    }

    func testSettingsPrivacy() throws {
        try captureSettings(tab: 1, titled: "Privacy", named: "settings-privacy")
    }

    func testSettingsParticipants() throws {
        try captureSettings(tab: 2, titled: "Participants", named: "settings-participants")
    }

    func testSettingsUpdates() throws {
        try captureSettings(tab: 3, titled: "Updates", named: "settings-updates")
    }

    func testSettingsCallback() throws {
        try captureSettings(
            tab: 4,
            titled: "Callback",
            named: "settings-callback",
            extraArguments: ["-transcriptCallbackCommand", #"claude -p "Turn my action items into tasks""#]
        )
    }

    func testSettingsAgents() throws {
        try captureSettings(tab: 5, titled: "Agents", named: "settings-agents")
    }

    // MARK: - Onboarding

    /// The walkthrough as a first run actually reaches it: an empty home, and the
    /// completed flag off rather than absent (see the note on preferences above).
    /// With the flag off the walkthrough window claims launch and the library window
    /// is suppressed, so this is the one shot that isn't the app's main window.
    func testOnboardingWelcome() throws {
        let app = launch(
            home: try freshHome(),
            arguments: [
                "-SUEnableAutomaticChecks", "NO",
                "-SUAutomaticallyUpdate", "NO",
                "-onboardingHasCompleted", "NO",
            ]
        )
        // Matched positionally like the library, and for a stronger reason: the
        // walkthrough is `.hiddenTitleBar`, so matching it on "Welcome to Cheerio"
        // would rest on a title no title bar is drawing. With the flag off it's also
        // the only window the app opens.
        capture(soleWindow(of: app), named: "onboarding-welcome")
    }

    // MARK: - Shots

    private func captureSettings(
        tab: Int,
        titled title: String,
        named name: String,
        extraArguments: [String] = []
    ) throws {
        let app = try launchSeeded(
            Self.libraryArguments + [
                "-screenshotOpenSettings", "YES",
                "-com_apple_SwiftUI_Settings_selectedTabIndex", String(tab),
            ] + extraArguments
        )
        capture(window(of: app, titled: title), named: name)
    }

    /// Attaches the element's picture under a deterministic name.
    ///
    /// `.keepAlways` is what puts it in the `.xcresult` for a passing test — the
    /// default (`.deleteOnSuccess`) would leave the workflow with attachments only
    /// when something went wrong, which is the opposite of the point. The name is the
    /// filename the workflow publishes, via `suggestedHumanReadableName` in
    /// `xcresulttool`'s manifest.
    private func capture(_ element: XCUIElement, named name: String) {
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = "\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Launching

    /// Launches against the demo store the workflow seeded.
    private func launchSeeded(_ arguments: [String]) throws -> XCUIApplication {
        let home = ProcessInfo.processInfo.environment["CHEERIO_SCREENSHOT_HOME"] ?? Self.defaultSeededHome
        let store = URL(filePath: home).appending(path: "Library/Application Support/app.cheerio.mac")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: store.path),
            """
            No seeded demo store at \(store.path).
            Run `Scripts/screenshots/seed-store.sh` first, or set CHEERIO_SCREENSHOT_HOME \
            (TEST_RUNNER_CHEERIO_SCREENSHOT_HOME for xcodebuild) to a home that has one. \
            These tests photograph a store full of invented meetings; they never open yours.
            """
        )
        return launch(home: URL(filePath: home), arguments: arguments)
    }

    /// An empty home, for the shots that have to look like a first run.
    private func freshHome() throws -> URL {
        let home = URL(filePath: NSTemporaryDirectory())
            .appending(path: "cheerio-screenshots-fresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    /// `CFFIXED_USER_HOME` is what actually relocates `~/Library/Application Support`
    /// and the SwiftData store inside it: Foundation resolves the home directory
    /// through CoreFoundation, which reads that variable and ignores `HOME`. `HOME` is
    /// set as well, for anything that shells out.
    private func launch(home: URL, arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CFFIXED_USER_HOME"] = home.path
        app.launchEnvironment["HOME"] = home.path
        app.launchArguments = arguments
        app.launch()
        self.app = app
        return app
    }

    // MARK: - Windows

    /// The app's one window, for the shots where it has exactly one.
    ///
    /// Matched positionally rather than by title, because neither of those windows has
    /// a title worth matching: the library's is the *selected meeting's* name, which
    /// moves with the demo data, and the walkthrough's title bar is hidden.
    private func soleWindow(of app: XCUIApplication) -> XCUIElement {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: Self.windowTimeout), "The app never opened a window.")
        Thread.sleep(forTimeInterval: Self.settle)
        return window
    }

    private func window(of app: XCUIApplication, titled title: String) -> XCUIElement {
        let window = app.windows[title]
        XCTAssertTrue(
            window.waitForExistence(timeout: Self.windowTimeout),
            "No window titled “\(title)” — the app opened \(app.windows.count) window(s)."
        )
        Thread.sleep(forTimeInterval: Self.settle)
        return window
    }
}
