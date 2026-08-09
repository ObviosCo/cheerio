import Foundation
import Testing

@testable import CheerioKit

@Suite struct EnrolledSpeakerTests {
    @Test func confirmationMessageIsPersonalAndUnexcited() {
        #expect(EnrolledSpeaker.confirmationMessage(forName: "Jackson") == "Thanks, Jackson. You're all set.")
        #expect(!EnrolledSpeaker.confirmationMessage(forName: "Jackson").contains("!"))
    }

    @Test func confirmationMessageTrimsWhitespaceFromTheTypedName() {
        #expect(EnrolledSpeaker.confirmationMessage(forName: "  Carter  ") == "Thanks, Carter. You're all set.")
    }
}
