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
/// each state without clicking. Every covered surface is audited twice — light and
/// dark — through `-screenshotAppearance`, because a contrast failure usually lives
/// in exactly one appearance. That now includes the live-recording pane, which was
/// unreachable until #164: it renders only while a session believes it's recording,
/// and `ScreenshotMode`'s charter is that nothing there can record. What's audited
/// is `RecordingSurface` — the shipped content view — fed fixture values by
/// `RecordingSurfacePreview`, with the session still `.idle`.
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
    /// walkthrough, and a fixed window size.
    ///
    /// 960×640, deliberately *smaller* than the screenshots' 1440×900: the CI
    /// runner's display is 1024×768, and a window bigger than the screen gets
    /// centered at a negative origin — a third of the sidebar hanging off-screen,
    /// with accessibility frames and rendered pixels disagreeing about where
    /// everything is. An audit needs every frame it measures to be where the
    /// pixels are; the screenshots keep their own size for diffable output.
    private static let libraryArguments = [
        "-SUEnableAutomaticChecks", "NO",
        "-SUAutomaticallyUpdate", "NO",
        "-onboardingHasCompleted", "YES",
        "-screenshotWindowSize", "960x640",
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
        try auditSeededLibrary(
            appearance: .light,
            extraArguments: ["-screenshotSelectMeeting", "1"],
            anchoredOn: Self.selectedMeetingAnchor
        )
    }

    func testLibrarySelectedRowDark() throws {
        try auditSeededLibrary(
            appearance: .dark,
            extraArguments: ["-screenshotSelectMeeting", "1"],
            anchoredOn: Self.selectedMeetingAnchor
        )
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
            extraArguments: ["-screenshotSelectMeeting", "2", "-screenshotExpandTranscript", "YES"],
            anchoredOn: Self.expandedTranscriptAnchor
        )
    }

    func testLibraryTranscriptDark() throws {
        try auditSeededLibrary(
            appearance: .dark,
            extraArguments: ["-screenshotSelectMeeting", "2", "-screenshotExpandTranscript", "YES"],
            anchoredOn: Self.expandedTranscriptAnchor
        )
    }

    /// The speakers panel's "Use as voice sample" sheet, presented over the
    /// selected meeting via `-screenshotEnrollFromMeetingSheet` — the sheet is
    /// otherwise only reachable through a row's ellipsis menu, which this harness
    /// never clicks, and its text (headline, explanation, the under-30s
    /// `StatusLabel`) exists on no other screen.
    func testEnrollFromMeetingSheetLight() throws {
        try auditEnrollSheet(appearance: .light)
    }

    func testEnrollFromMeetingSheetDark() throws {
        try auditEnrollSheet(appearance: .dark)
    }

    /// Nothing selected: the empty-state dashboard (#124).
    func testLibraryEmptyStateLight() throws {
        try auditSeededLibrary(appearance: .light, anchoredOn: Self.dashboardAnchor)
    }

    func testLibraryEmptyStateDark() throws {
        try auditSeededLibrary(appearance: .dark, anchoredOn: Self.dashboardAnchor)
    }

    /// The same dashboard with issue #125's voice-enrollment prompt on it, which
    /// only renders when the store has meetings but no enrolled voices.
    func testLibraryEmptyStateNoEnrollmentLight() throws {
        try auditNoEnrollmentLibrary(appearance: .light)
    }

    func testLibraryEmptyStateNoEnrollmentDark() throws {
        try auditNoEnrollmentLibrary(appearance: .dark)
    }

    /// A transcript whose speakers were never identified — `Speaker 1` and `Me`
    /// rather than names. `SpeakerRailLabel` styles those two rungs differently
    /// from a matched name (#162), and the enrolled store has no line in either
    /// state, so this is the only screen that measures them. The no-enrollment
    /// store's first meeting is the multi-voice one: both channels, three numbered
    /// speakers on the far end, and one hand-named line among them.
    func testUnidentifiedSpeakerTranscriptLight() throws {
        try auditNoEnrollmentTranscript(appearance: .light)
    }

    func testUnidentifiedSpeakerTranscriptDark() throws {
        try auditNoEnrollmentTranscript(appearance: .dark)
    }

    // MARK: - Recording

    /// The live-recording pane: the timer and ring, the transcript with both
    /// channels on it, the scratchpad's placeholder, and the enrollment nudge
    /// banner, none of which any other audit here can reach.
    ///
    /// What's on screen is `RecordingSurface` — `RecordingView`'s own content
    /// view — fed fixture values by `RecordingSurfacePreview`, with the session
    /// still `.idle`. The alternative was a seam that made `CaptureSession`
    /// report a recording it isn't running, and that state is what the menu bar,
    /// update gating and the deletion guards all key off; see #164.
    func testRecordingLight() throws { try auditRecordingSurface(.recording, appearance: .light) }
    func testRecordingDark() throws { try auditRecordingSurface(.recording, appearance: .dark) }

    /// The post-meeting holding state (#136), which carries controls and copy the
    /// recording state doesn't: the countdown to auto-processing, the meeting-kind
    /// switch, and the callback toggle with its per-meeting prompt.
    func testRecordingHoldingLight() throws { try auditRecordingSurface(.holding, appearance: .light) }
    func testRecordingHoldingDark() throws { try auditRecordingSurface(.holding, appearance: .dark) }

    /// The fixture states `-screenshotRecordingPreview` accepts, spelled here
    /// rather than shared with the app target — a test bundle that imported the
    /// app's enum would fail to compile before it could report the drift, where a
    /// wrong string fails on the anchor with a message that says what's missing.
    private enum RecordingVariant: String {
        case recording
        case holding

        /// Text only this variant puts on screen, so a hook that silently stopped
        /// working can't leave the audit measuring the dashboard and passing.
        var anchor: String {
            switch self {
            // "Live" is a claim about capture, which the holding state has to
            // stop making — the two headers differ for exactly that reason.
            case .recording: "Live transcript"
            case .holding: "Recording finished. Processing starts in"
            }
        }

        /// The holding state's callback toggle and prompt only render when a
        /// trigger exists that could actually run, so this launch configures one
        /// — the same argument `ScreenshotCaptureTests` uses for the Callback
        /// tab. It leaves one trigger, which is the shape that hides the
        /// per-meeting trigger picker (#137); that picker needs a trigger *list*,
        /// and a list is a JSON blob no launch argument can carry.
        var extraArguments: [String] {
            switch self {
            case .recording: []
            case .holding: ["-transcriptCallbackCommand", #"claude -p "Turn my action items into tasks""#]
            }
        }
    }

    private func auditRecordingSurface(_ variant: RecordingVariant, appearance: Appearance) throws {
        let app = try launchSeeded(
            Self.libraryArguments + ["-screenshotRecordingPreview", variant.rawValue] + variant.extraArguments,
            appearance: appearance
        )
        awaitWindow(of: app)
        // Matched on a prefix: the holding banner's countdown is a live timer, so
        // its label reads differently every second.
        let anchor = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", variant.anchor)
        ).firstMatch
        try requireAnchor(anchor)
        try requireEffectiveAppearance(appearance, in: app)
        try audit(app)
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

    /// The same tab with `VoiceEnrollmentRecorder`'s post-save acknowledgment
    /// (issue #128) forced on — a state with its own text (`StatusLabel(.success)`
    /// over the form) that only exists after a real 30-second sample, so the
    /// launch-argument hook is the only way an audit ever sees it. The screenshot
    /// harness treats it as its own surface for the same reason.
    func testSettingsParticipantsConfirmedLight() throws {
        try auditSettings(
            tab: 2,
            titled: "Participants",
            appearance: .light,
            extraArguments: ["-screenshotVoiceEnrollmentConfirmed", "YES"]
        )
    }

    func testSettingsParticipantsConfirmedDark() throws {
        try auditSettings(
            tab: 2,
            titled: "Participants",
            appearance: .dark,
            extraArguments: ["-screenshotVoiceEnrollmentConfirmed", "YES"]
        )
    }

    func testSettingsUpdatesLight() throws { try auditSettings(tab: 3, titled: "Updates", appearance: .light) }
    func testSettingsUpdatesDark() throws { try auditSettings(tab: 3, titled: "Updates", appearance: .dark) }

    func testSettingsCallbackLight() throws { try auditSettings(tab: 4, titled: "Callback", appearance: .light) }
    func testSettingsCallbackDark() throws { try auditSettings(tab: 4, titled: "Callback", appearance: .dark) }

    func testSettingsAgentsLight() throws { try auditSettings(tab: 5, titled: "Agents", appearance: .light) }
    func testSettingsAgentsDark() throws { try auditSettings(tab: 5, titled: "Agents", appearance: .dark) }

    // MARK: - Onboarding

    /// The walkthrough's first step, reached the way a real first run reaches it:
    /// an empty home with the completed flag off.
    func testOnboardingWelcomeLight() throws { try auditOnboardingWelcome(appearance: .light) }
    func testOnboardingWelcomeDark() throws { try auditOnboardingWelcome(appearance: .dark) }

    // The other six steps, opened directly with `-screenshotOnboardingStep` (raw
    // values of `OnboardingCoordinator.Step`) — the steps share `OnboardingScaffold`
    // but each carries its own captions, and the permission steps' explanatory text
    // exists on no other screen. Against the seeded home with the completed flag
    // on, because the step argument is applied from the *library* window's launch
    // task, which a genuine first run never reaches; the library window is closed
    // once the walkthrough is up, for the same overlap reason as Settings. The
    // permission steps' granted/denied status captions have no launch-argument
    // hook — the harness never asks macOS for anything — so those states stay
    // unaudited here.

    func testOnboardingMicrophoneLight() throws {
        try auditOnboardingStep(1, titled: "Hear your side of the conversation", appearance: .light)
    }

    func testOnboardingMicrophoneDark() throws {
        try auditOnboardingStep(1, titled: "Hear your side of the conversation", appearance: .dark)
    }

    func testOnboardingSystemAudioLight() throws {
        try auditOnboardingStep(2, titled: "Hear everyone else's side, too", appearance: .light)
    }

    func testOnboardingSystemAudioDark() throws {
        try auditOnboardingStep(2, titled: "Hear everyone else's side, too", appearance: .dark)
    }

    func testOnboardingCalendarLight() throws {
        try auditOnboardingStep(3, titled: "Match meetings to your calendar", appearance: .light)
    }

    func testOnboardingCalendarDark() throws {
        try auditOnboardingStep(3, titled: "Match meetings to your calendar", appearance: .dark)
    }

    func testOnboardingVoiceEnrollmentLight() throws {
        try auditOnboardingStep(4, titled: "Put a name to your voice", appearance: .light)
    }

    func testOnboardingVoiceEnrollmentDark() throws {
        try auditOnboardingStep(4, titled: "Put a name to your voice", appearance: .dark)
    }

    func testOnboardingTeammateVoicesLight() throws {
        try auditOnboardingStep(5, titled: "Recognize everyone, not just you", appearance: .light)
    }

    func testOnboardingTeammateVoicesDark() throws {
        try auditOnboardingStep(5, titled: "Recognize everyone, not just you", appearance: .dark)
    }

    func testOnboardingFinishLight() throws {
        try auditOnboardingStep(6, titled: "You're all set", appearance: .light)
    }

    func testOnboardingFinishDark() throws {
        try auditOnboardingStep(6, titled: "You're all set", appearance: .dark)
    }

    // MARK: - Audits

    /// Runs the audit over everything the app currently has on screen, filtering
    /// each finding through ``shouldSuppress(_:in:)`` — see the type-level comment
    /// for the standard a suppression rule has to meet.
    ///
    /// `sheet` limits an audit to one presented surface: with a modal sheet up,
    /// everything behind it renders through the sheet's dimming veil —
    /// de-emphasis macOS applies on purpose, to content that is neither
    /// interactive nor meant to be read right now, and content every one of
    /// those elements gets audited *undimmed* by this suite's other cases.
    ///
    /// Membership in the sheet's own accessibility hierarchy is what separates
    /// the surface under audit from that backdrop — not screen coordinates,
    /// which were only ever a proxy: the library sits geometrically *behind* the
    /// sheet, so its elements intersect the same rect while belonging to a
    /// different surface entirely. The descendants are snapshotted once, before
    /// the audit, keyed on type, label, and rounded frame.
    private func audit(_ app: XCUIApplication, withinSheet sheet: XCUIElement? = nil) throws {
        let members: Set<String>? = sheet.map { sheet in
            var keys = Set<String>()
            for element in sheet.descendants(matching: .any).allElementsBoundByIndex {
                keys.insert(Self.membershipKey(of: element))
            }
            return keys
        }
        try app.performAccessibilityAudit(for: Self.auditTypes) { issue in
            if let members, let element = issue.element, element.exists,
                !members.contains(Self.membershipKey(of: element))
            {
                return true
            }
            return self.shouldSuppress(issue, in: app)
        }
    }

    /// Identity for hierarchy membership: enough to match the same element
    /// between the descendants snapshot and an audit issue, while the frame's
    /// rounding forgives sub-pixel drift and nothing more.
    private static func membershipKey(of element: XCUIElement) -> String {
        let frame = element.frame
        return [
            String(element.elementType.rawValue),
            element.label,
            String(Int(frame.minX.rounded())),
            String(Int(frame.minY.rounded())),
            String(Int(frame.width.rounded())),
            String(Int(frame.height.rounded())),
        ].joined(separator: "|")
    }

    // The library states' anchors — one element per state that only exists once
    // that state's launch argument took effect, so a hook that silently stops
    // working fails the test instead of leaving it auditing the default library
    // and passing. Same guard the Settings, sheet, and walkthrough audits carry.

    /// "Rough notes" is the detail pane's own section heading — the dashboard
    /// renders when nothing is selected, and it has no such text.
    private static func selectedMeetingAnchor(in app: XCUIApplication) -> XCUIElement {
        app.staticTexts["Rough notes"]
    }

    /// The transcript's first minute stamp only renders with the disclosure
    /// *expanded* and segments in it — exactly the two things this state is for.
    private static func expandedTranscriptAnchor(in app: XCUIApplication) -> XCUIElement {
        app.staticTexts["0:00"]
    }

    /// The stats heading renders on the dashboard and nowhere in a meeting's
    /// detail pane.
    private static func dashboardAnchor(in app: XCUIApplication) -> XCUIElement {
        app.staticTexts["This week"]
    }

    /// Issue #125's prompt — the whole point of the no-enrollment store.
    private static func enrollmentPromptAnchor(in app: XCUIApplication) -> XCUIElement {
        app.buttons["Enroll your voice"]
    }

    /// A diarizer-generated name anywhere in the hierarchy. Matched by substring
    /// across every element type on purpose: the rail label is a `Menu`'s label, so
    /// whether it surfaces as its own static text or folded into the button's is
    /// SwiftUI's business, and pinning it to either would make this anchor a
    /// tripwire for the wrong thing.
    private static func unidentifiedSpeakerAnchor(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Speaker 1"))
            .firstMatch
    }

    private func auditSeededLibrary(
        appearance: Appearance,
        extraArguments: [String] = [],
        anchoredOn anchor: (XCUIApplication) -> XCUIElement
    ) throws {
        let app = try launchSeeded(Self.libraryArguments + extraArguments, appearance: appearance)
        awaitWindow(of: app)
        try requireAnchor(anchor(app))
        try requireEffectiveAppearance(appearance, in: app)
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
        try requireAnchor(Self.selectedMeetingAnchor(in: app))
        try requireEffectiveAppearance(appearance, in: app)
        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        // The state assertion, not just a sleep: if Finder never actually took
        // activation, this would re-audit `Accent/Selection` and quietly leave
        // the inactive fill uncovered.
        XCTAssertTrue(
            app.wait(for: .runningBackground, timeout: Self.windowTimeout),
            "Finder never took activation — the inactive selection fill was never on screen."
        )
        guard app.state == .runningBackground else { return }
        // The redraw to the inactive fill has nothing observable; same reasoning
        // as `settle`.
        Thread.sleep(forTimeInterval: 1)
        try audit(app)
    }

    /// A missing anchor aborts the test rather than letting it audit — and pass
    /// against — a state it can't prove. The assertion carries the message; the
    /// thrown error is only what stops the run.
    private struct MissingAnchor: Error {}

    private func requireAnchor(_ element: XCUIElement) throws {
        XCTAssertTrue(
            element.waitForExistence(timeout: Self.windowTimeout),
            "The audited state's anchor never appeared."
        )
        guard element.exists else { throw MissingAnchor() }
    }

    /// The appearance anchor: each light/dark pair only halves an appearance bug
    /// in two if the app actually rendered both — if
    /// `ScreenshotMode.applyAppearanceOverride` regressed, every pair would
    /// audit the runner's default twice and pass. Verified the way everything
    /// else here is: from the rendered pixels, not the launch argument — the
    /// frontmost window's dominant color sits far above 0.5 relative luminance
    /// in light mode and far below it in dark, whatever surface is up.
    private func requireEffectiveAppearance(_ appearance: Appearance, in app: XCUIApplication) throws {
        let image = app.windows.firstMatch.screenshot().image
        guard
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let dominant = ContrastEvidence.dominantLuminance(in: cgImage)
        else {
            XCTFail("Couldn't sample the window to verify the effective appearance.")
            throw MissingAnchor()
        }
        let rendersDark = dominant < 0.5
        XCTAssertEqual(
            rendersDark,
            appearance == .dark,
            "The app rendered in the wrong appearance — `-screenshotAppearance \(appearance.rawValue)` didn't take."
        )
        guard rendersDark == (appearance == .dark) else { throw MissingAnchor() }
    }

    private func auditEnrollSheet(appearance: Appearance) throws {
        let app = try launchSeeded(
            Self.libraryArguments + [
                "-screenshotSelectMeeting", "1",
                "-screenshotEnrollFromMeetingSheet", "YES",
            ],
            appearance: appearance
        )
        // The sheet's own headline, not just the window — if presenting it
        // regressed, an audit of the meeting behind it would read as green while
        // measuring nothing this test is for.
        let heading = app.staticTexts["Use as voice sample"]
        XCTAssertTrue(
            heading.waitForExistence(timeout: Self.windowTimeout),
            "The enrollment sheet never appeared."
        )
        guard heading.exists else { return }
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.exists, "The headline rendered outside a sheet — the scope below would be wrong.")
        guard sheet.exists else { return }
        Thread.sleep(forTimeInterval: Self.settle)
        // Scoped to the sheet: the library behind it renders through the modal
        // dimming veil, and every one of those elements is audited undimmed by
        // the other cases here — see `audit(_:withinSheet:)`.
        try requireEffectiveAppearance(appearance, in: app)
        try audit(app, withinSheet: sheet)
    }

    private func auditSettings(
        tab: Int,
        titled title: String,
        appearance: Appearance,
        extraArguments: [String] = []
    ) throws {
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
            ] + extraArguments,
            appearance: appearance
        )
        let window = app.windows[title]
        XCTAssertTrue(
            window.waitForExistence(timeout: Self.windowTimeout),
            "No window titled “\(title)” — the app opened \(app.windows.count) window(s)."
        )
        Thread.sleep(forTimeInterval: Self.settle)
        try requireEffectiveAppearance(appearance, in: app)
        try audit(app)
    }

    /// Waits on the *step's own title* and on the library window being gone, not
    /// just on "some window exists" — if opening the walkthrough regressed, the
    /// close hook would leave the app with no windows at all, and an audit of
    /// nothing reports nothing, which would read as green. An audit that ran
    /// against nothing has to fail instead.
    private func auditOnboardingStep(_ step: Int, titled title: String, appearance: Appearance) throws {
        let app = try launchSeeded(
            Self.libraryArguments + [
                "-screenshotOnboardingStep", String(step),
                "-screenshotCloseMainWindow", "YES",
            ],
            appearance: appearance
        )
        let heading = app.staticTexts[title]
        XCTAssertTrue(
            heading.waitForExistence(timeout: Self.windowTimeout),
            "The walkthrough never showed “\(title)”."
        )
        guard heading.exists else { return }
        XCTAssertTrue(
            app.windows["Cheerio"].waitForNonExistence(timeout: Self.windowTimeout),
            "The library window never closed behind the walkthrough."
        )
        Thread.sleep(forTimeInterval: Self.settle)
        try requireEffectiveAppearance(appearance, in: app)
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
        try requireEffectiveAppearance(appearance, in: app)
        try audit(app)
    }

    // MARK: - Suppression

    /// Whether a finding is one of the audit's known measurement artifacts rather
    /// than a color problem in the app. Everything here re-checks evidence about
    /// *this* element at *this* moment — no rule matches on name, screen, or
    /// appearance, so a genuine regression on a suppressed element's twin still
    /// fails — and every rule resolves ambiguity toward *failing*: when the
    /// evidence can't positively clear a finding, the check goes red and a person
    /// decides.
    ///
    /// Three rules, each grounded in the first runs' measured findings (see the
    /// type-level comment):
    ///
    /// 1. **The element isn't at its own hit point.** Content scrolled out of a
    ///    viewport keeps its accessibility element; what the audit sampled there is
    ///    whatever ended up drawn at those coordinates instead. Not hittable is
    ///    AX's own positive statement of that.
    ///
    /// 2. **The frame extends past every window the app has.** A clipped element
    ///    at a scroll boundary reports a frame that crosses the window's edge, so
    ///    part of the sampled region is provably not the app's rendering at all —
    ///    one measured finding was 41% desktop wallpaper. An empty frame is the
    ///    degenerate case: no drawable area, nothing sampled was the element.
    ///
    /// 3. **The rendered pixels prove AA, for plain text only.** On the runner's
    ///    1x display the audit flags small text whose core glyph pixels measure
    ///    well past 4.5:1 — the first run flagged one element at a measured
    ///    17.3:1 — because antialiased edge pixels dominate a small glyph's
    ///    coverage. ``measuredTextContrast(of:)`` re-measures the element's own
    ///    screenshot and suppresses only when *every* distinguishable ink clears
    ///    4.5:1 — each remaining color has to be a geometric blend of a passing
    ///    ink with the background (what antialiasing produces) or background
    ///    texture; anything else — an icon, a border, a weaker ink off every
    ///    blend line — can't be cleared and stays red.
    private func shouldSuppress(_ issue: XCUIAccessibilityAuditIssue, in app: XCUIApplication) -> Bool {
        guard let element = issue.element, element.exists else { return false }
        if !element.isHittable { return true }
        let frame = element.frame
        if frame.isEmpty { return true }
        let windows = app.windows.allElementsBoundByIndex
        if !windows.contains(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(frame) }) {
            return true
        }
        guard element.elementType == .staticText else { return false }
        guard let measured = Self.measuredTextContrast(of: element) else { return false }
        return measured >= ContrastEvidence.aaContrast
    }

    /// The rendered contrast of a text element, measured from its own screenshot.
    /// The measurement itself is ``ContrastEvidence`` — pure, and pinned by
    /// `ContrastEvidenceTests` to refuse what it can't prove; this only gets the
    /// pixels out of XCUITest's hands.
    private static func measuredTextContrast(of element: XCUIElement) -> Double? {
        let image = element.screenshot().image
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return ContrastEvidence.measuredTextContrast(in: cgImage)
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
        try requireAnchor(Self.enrollmentPromptAnchor(in: app))
        try requireEffectiveAppearance(appearance, in: app)
        try audit(app)
    }

    private func auditNoEnrollmentTranscript(appearance: Appearance) throws {
        let app = try launchNoEnrollment(
            Self.libraryArguments + ["-screenshotSelectMeeting", "1", "-screenshotExpandTranscript", "YES"],
            appearance: appearance
        )
        awaitWindow(of: app)
        try requireAnchor(Self.expandedTranscriptAnchor(in: app))
        // A generated label on screen, not just an expanded transcript: if the
        // seeder ever went back to writing names into this store, the audit would
        // measure four matched labels and report green on a state it never saw.
        try requireAnchor(Self.unidentifiedSpeakerAnchor(in: app))
        try requireEffectiveAppearance(appearance, in: app)
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
