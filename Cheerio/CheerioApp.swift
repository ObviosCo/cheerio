import CheerioKit
import SwiftData
import SwiftUI

@main
struct CheerioApp: App {
    @State private var captureSession = CaptureSession()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(captureSession)
        }
        .modelContainer(for: [Meeting.self, TranscriptSegment.self])
    }
}

struct ContentView: View {
    @Environment(CaptureSession.self) private var session

    var body: some View {
        NavigationSplitView {
            MeetingListView()
        } detail: {
            if session.state == .recording || session.state == .finishing {
                RecordingView()
            } else {
                ContentUnavailableView(
                    "No meeting selected",
                    systemImage: "text.bubble",
                    description: Text("Select a past meeting or start recording.")
                )
            }
        }
    }
}
