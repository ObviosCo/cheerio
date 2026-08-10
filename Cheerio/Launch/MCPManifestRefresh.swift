import CheerioKit
import Foundation
import os

/// The app side of MCP discovery (issue #135): on launch, refresh the manifest that
/// tells local agents where this copy's `cheerio-mcp` helper is. All of the what and
/// why — location, format, staleness contract — lives with `MCPDiscoveryManifest` in
/// CheerioKit; this is just where the app's own bundle location and version get read
/// and the work gets scheduled.
enum MCPManifestRefresh {
    private static let log = Logger(subsystem: "co.obvios.cheerio.mac", category: "MCP")

    /// Called from `CheerioApp.init()`, which is also what keeps it clear of capture:
    /// launch runs exactly once, before `CaptureSession` could have started anything.
    /// The write itself happens off the main actor — it's a disk touch nobody should
    /// wait on — and failure is logged rather than surfaced, because discovery is an
    /// extra path to the server, not a load-bearing one: Settings' copy-paste setup
    /// works whether or not this file ever lands.
    static func runAtLaunch() {
        let appBundle = Bundle.main.bundleURL
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        Task.detached(priority: .utility) {
            do {
                switch try MCPDiscoveryManifest.refreshAtLaunch(appBundle: appBundle, version: version) {
                case .written(let url):
                    log.info("Discovery manifest written: \(url.path, privacy: .public)")
                case .helperMissing:
                    // A build without the helper (a partial copy, or a stripped-down
                    // dev build) has nothing true to advertise; any manifest a real
                    // install wrote stays as it was.
                    log.notice("Discovery manifest not written: no helper in this bundle")
                }
            } catch {
                log.error("Discovery manifest refresh failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
