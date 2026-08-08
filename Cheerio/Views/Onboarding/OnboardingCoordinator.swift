import Foundation

/// Walks the onboarding window through its steps in order. Deliberately dumb: no
/// step here can fail or refuse to advance, because nothing in this walkthrough is
/// allowed to gate on anything (see `OnboardingView`'s doc comment).
@MainActor
@Observable
final class OnboardingCoordinator {
    enum Step: Int, CaseIterable {
        case welcome
        case microphone
        case systemAudio
        case calendar
        case voiceEnrollment
        case teammateVoices
        case finish
    }

    /// Starts on the first step, unless the screenshot harness asked for a later one
    /// so it can photograph it — see `ScreenshotMode`. An out-of-range value falls
    /// back to `.welcome` rather than failing.
    private(set) var step: Step = ScreenshotMode.onboardingStep.flatMap(Step.init(rawValue:)) ?? .welcome

    func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }
}
