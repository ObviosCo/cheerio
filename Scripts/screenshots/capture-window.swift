import AppKit
import CoreGraphics
import Foundation

// Captures one window of a running process, at the display's native scale.
//
//     capture-window --pid <pid> --out <file.png> [--title-contains <text>]
//                    [--smallest] [--timeout <seconds>]
//
// Three things have to happen in order, which is why this is a program rather than
// a line of shell:
//
// 1. Find the window. `CGWindowListCopyWindowInfo` is the only way to get the window
//    *number* `screencapture -l` wants; there's no "capture the frontmost window of
//    pid N" flag. Windows are matched on the owning pid — never on the app name, so
//    a real Cheerio the user happens to be running can't be photographed by mistake.
// 2. Activate the app first. A window that isn't frontmost gets captured as whatever
//    the window server currently has for it — under Stage Manager that's the shrunken,
//    perspective-skewed thumbnail from the side strip, and `screencapture` returns
//    success with a 200×218 image of it.
// 3. Wait for the window to actually be there. The app is launched a moment earlier
//    and SwiftUI's first frame isn't instant.

struct Options {
    var pid: pid_t = -1
    var out = ""
    var titleContains: String?
    /// Picks the narrowest matching window instead of the frontmost — how the
    /// Settings window is told apart from the library window behind it.
    var smallest = false
    var timeout: TimeInterval = 20
}

var options = Options()
var arguments = Array(CommandLine.arguments.dropFirst())
while let flag = arguments.first {
    arguments.removeFirst()
    func next() -> String {
        guard let value = arguments.first else {
            FileHandle.standardError.write(Data("missing value for \(flag)\n".utf8))
            exit(2)
        }
        arguments.removeFirst()
        return value
    }
    switch flag {
    case "--pid": options.pid = pid_t(next()) ?? -1
    case "--out": options.out = next()
    case "--title-contains": options.titleContains = next()
    case "--smallest": options.smallest = true
    case "--timeout": options.timeout = TimeInterval(next()) ?? 20
    default:
        FileHandle.standardError.write(Data("unknown flag \(flag)\n".utf8))
        exit(2)
    }
}
guard options.pid > 0, !options.out.isEmpty else {
    FileHandle.standardError.write(Data("usage: capture-window --pid <pid> --out <file.png>\n".utf8))
    exit(2)
}

struct Window {
    let id: Int
    let title: String
    let width: CGFloat
    let height: CGFloat
}

/// The pixel dimensions of a PNG, without decoding it.
func pixelSize(of path: String) -> (width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithURL(URL(filePath: path) as CFURL, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return (width, height)
}

func windows(for pid: pid_t) -> [Window] {
    let list =
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    return list.compactMap { entry in
        guard (entry[kCGWindowOwnerPID as String] as? pid_t) == pid,
            (entry[kCGWindowLayer as String] as? Int) == 0,
            let id = entry[kCGWindowNumber as String] as? Int,
            let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
            let width = bounds["Width"], let height = bounds["Height"],
            // Panels and the odd transient host window are too small to be a
            // window anyone wants a picture of.
            width > 200, height > 200
        else { return nil }
        return Window(
            id: id, title: entry[kCGWindowName as String] as? String ?? "",
            width: width, height: height)
    }
}

func matches(_ window: Window) -> Bool {
    guard let wanted = options.titleContains else { return true }
    return window.title.localizedCaseInsensitiveContains(wanted)
}

func findWindow() -> Window? {
    let deadline = Date.now.addingTimeInterval(options.timeout)
    while Date.now < deadline {
        // Every pass, not once before the loop: an `activate` issued while the app
        // is still starting does nothing, and with Stage Manager on, an app that
        // never came forward has only its shrunken side-strip thumbnail on screen —
        // which is below the size filter, so the loop would spin until it timed out
        // with the window sitting right there.
        NSRunningApplication(processIdentifier: options.pid)?.activate(options: [])
        let found = windows(for: options.pid).filter(matches)
        if !found.isEmpty {
            // The list is in front-to-back order, so the first match is the frontmost.
            return options.smallest ? found.min(by: { $0.width < $1.width }) : found.first
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    return nil
}

/// Three tries, because `screencapture` occasionally answers "could not create
/// image from window" — the window server losing the window between the moment it
/// was listed and the moment it was asked for. The window is looked up again each
/// time rather than the id being reused, since a window that went away has a new
/// number when it comes back.
for attempt in 1...3 {
    guard let window = findWindow() else {
        FileHandle.standardError.write(
            Data("no window for pid \(options.pid) matching \(options.titleContains ?? "(any)")\n".utf8))
        exit(1)
    }

    // Re-activate and let the window settle. Without the pause the capture lands on
    // a frame from before the app came forward; at 1.2s it still sometimes caught
    // the toolbar mid-way through picking up the selected meeting's title, so two
    // runs differed by one line of text.
    NSRunningApplication(processIdentifier: options.pid)?.activate(options: [])
    Thread.sleep(forTimeInterval: 2)

    let capture = Process()
    capture.executableURL = URL(filePath: "/usr/sbin/screencapture")
    // -o drops the drop shadow (the website draws its own border), -x silences the
    // shutter sound, -l picks the window by number.
    capture.arguments = ["-l\(window.id)", "-o", "-x", options.out]
    try capture.run()
    capture.waitUntilExit()

    // Two ways this comes back wrong, both of which `screencapture` calls success:
    // no file at all, and — the nasty one — a picture of the Stage Manager thumbnail
    // instead of the window, which happens when the app didn't come forward. The
    // thumbnail is a couple of hundred pixels across, so the size settles it: a real
    // capture is at least as many pixels as the window is points.
    let captured = pixelSize(of: options.out)
    if capture.terminationStatus == 0, let captured,
        captured.width >= Int(window.width), captured.height >= Int(window.height)
    {
        print("captured \(window.id) “\(window.title)” → \(options.out)")
        exit(0)
    }
    let describedSize = captured.map { "\($0.width)×\($0.height)" } ?? "nothing"
    try? FileManager.default.removeItem(atPath: options.out)
    FileHandle.standardError.write(
        Data(
            """
            attempt \(attempt): expected at least \(Int(window.width))×\(Int(window.height)) \
            points of window, got \(describedSize) — retrying\n
            """.utf8))
    Thread.sleep(forTimeInterval: 1.5)
}

FileHandle.standardError.write(Data("could not capture a window for pid \(options.pid)\n".utf8))
exit(1)
