import Foundation

/// Locates recorded meeting audio inside the app's Application Support directory.
///
/// `Meeting.audioDirectory` stores the path *relative* to Application Support so the
/// store stays valid if the container moves.
public enum AudioStorage {
    /// Path component under our container that holds every meeting's audio.
    private static let meetingsFolder = "Meetings"

    /// The app's bundle identifier, which is also the name of its Application
    /// Support container.
    ///
    /// A constant, not `Bundle.main.bundleIdentifier`, for anything that isn't the
    /// app process: the MCP helper is a bare executable *inside* `Cheerio.app`, so
    /// its `Bundle.main` is the helper's own directory and its identifier is either
    /// nil or the helper's — never Cheerio's. The app still prefers its live value
    /// (see ``applicationSupport()``) and falls back to this.
    public static let appBundleIdentifier = "app.cheerio.mac"

    /// The shared, user-level Application Support directory — NOT where we write.
    /// Only used to migrate data written there before this was fixed.
    static func sharedApplicationSupport() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    /// Where Cheerio's container *would* be, creating nothing along the way.
    ///
    /// The read-only counterpart to ``applicationSupport()``, for consumers where a
    /// missing directory is the answer rather than something to fix — the MCP helper
    /// has to be able to say "the app has never run" instead of quietly conjuring an
    /// empty container next to the one it was looking for.
    public static func containerURL(bundleIdentifier: String = appBundleIdentifier) throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        .appending(path: bundleIdentifier, directoryHint: .isDirectory)
    }

    /// Everything Cheerio owns lives here.
    ///
    /// Without App Sandbox, `.applicationSupportDirectory` resolves to the *shared*
    /// `~/Library/Application Support`, so writing `Meetings/` straight into it
    /// collided with another app that already owned a folder by that name. An
    /// unsandboxed app has to namespace itself.
    public static func applicationSupport() throws -> URL {
        let container = try sharedApplicationSupport()
            .appending(path: Bundle.main.bundleIdentifier ?? appBundleIdentifier, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        return container
    }

    /// Filename of the SwiftData store inside our container. SwiftData's own
    /// default, kept because renaming it would strand every existing store.
    public static let storeFileName = "default.store"

    /// Where the SwiftData store lives, inside our container.
    public static func storeURL() throws -> URL {
        try applicationSupport().appending(path: storeFileName)
    }

    /// Creates a fresh directory for one meeting's audio and returns both the
    /// relative path to persist and the absolute URL to write into.
    public static func makeMeetingDirectory() throws -> (relativePath: String, url: URL) {
        let relativePath = "\(meetingsFolder)/\(UUID().uuidString)"
        let url = try applicationSupport().appending(path: relativePath, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (relativePath, url)
    }

    /// Path component holding voice samples for enrolled speakers.
    private static let speakersFolder = "Speakers"

    /// Creates a destination for one speaker's reference recording, returning both
    /// the relative path to persist and the absolute URL to write to.
    public static func makeSpeakerSampleFile() throws -> (relativePath: String, url: URL) {
        let relativePath = "\(speakersFolder)/\(UUID().uuidString).caf"
        let url = try applicationSupport().appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return (relativePath, url)
    }

    /// Removes a single file, e.g. a deleted speaker's voice sample.
    public static func removeFile(atRelativePath relativePath: String) throws {
        let url = try applicationSupport().appending(path: relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Resolves a stored relative path — a meeting's audio directory, or a speaker's
    /// sample file — against our container.
    ///
    /// `.inferFromPath` rather than `.isDirectory`: the latter appended a trailing
    /// slash to file paths too, giving speaker samples a URL like `…/abc.caf/`. That
    /// happens to work (`.path` drops the slash, so `fileExists` and reads succeed),
    /// but it's wrong on its face and only ever one API away from biting.
    public static func url(forRelativePath relativePath: String) throws -> URL {
        try applicationSupport().appending(path: relativePath, directoryHint: .inferFromPath)
    }

    /// Removes a meeting's audio directory. Succeeds quietly if it is already gone.
    public static func removeDirectory(atRelativePath relativePath: String) throws {
        let url = try url(forRelativePath: relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
