import Foundation
import Synchronization

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
    public static let appBundleIdentifier = "co.obvios.cheerio.mac"

    /// Cheerio's bundle identifier before the `co.obvios` rename (see the tracking
    /// epic, #22, and `BundleIdentifierMigration`).
    ///
    /// Kept as a named constant, not folded away once the migration ships, because
    /// three things still read it after every existing install has moved forward:
    /// ``BundleIdentifierMigration`` (to find the directory to move), the one-time
    /// `UserDefaultsMigration` (to find the preferences domain to copy), and the
    /// bundled MCP helper's ``containerURL(bundleIdentifier:)`` fallback for a user
    /// who runs the helper before ever launching the new app.
    public static let legacyBundleIdentifier = "app.cheerio.mac"

    /// The identifier Cheerio's own releases ship under — always
    /// `"co.obvios.cheerio.mac"`, literally, **never** read from
    /// ``appBundleIdentifier``.
    ///
    /// A fork is instructed (README.md's "Building your own fork" section) to
    /// change ``appBundleIdentifier``'s value to its own identifier — that's the
    /// constant the MCP helper and every container-path lookup are supposed to
    /// follow. If ``isRunningAsOfficialBuild(_:)`` also compared against
    /// ``appBundleIdentifier``, a *correctly configured* fork would set its own
    /// identifier there, its runtime identifier would then equal
    /// ``appBundleIdentifier`` by construction, and the check would come back
    /// `true` — turning the `app.cheerio.mac` migration and the DMG handoff's
    /// legacy match back on for a fork that never shipped under that identifier in
    /// the first place. This constant exists so that outcome is impossible: it
    /// names the one specific build the rename-only paths below are about, and
    /// nothing a fork does to its own identity constant can move it.
    ///
    /// **Do not change this value in a fork.** It gates machinery that is
    /// meaningless for a fork regardless of what identifier the fork uses — see
    /// ``isRunningAsOfficialBuild(_:)``.
    public static let officialBundleIdentifier = "co.obvios.cheerio.mac"

    /// Whether the running process is Cheerio's own official build —
    /// ``officialBundleIdentifier``, a fixed value, deliberately **not**
    /// ``appBundleIdentifier`` — rather than a fork built under its own identifier.
    ///
    /// Everything that assumes a pre-existing ``legacyBundleIdentifier`` install
    /// belongs to *this app* gates on this: `BundleIdentifierMigration` and
    /// `UserDefaultsMigration` (a fork never shipped under the old identifier, so
    /// there's nothing of its own to adopt there, and an unrelated app that happens
    /// to use it isn't this one's data to touch), and the DMG launch-location
    /// handoff's transitional identifier match (see
    /// `InstalledCopyLocator.acceptableBundleIdentifiers(runningAs:)`). Without this
    /// gate, a fork launched from a DMG could find an unrelated, independently
    /// installed `app.cheerio.mac` copy, mistake it for itself already installed,
    /// hand off to it, and quit.
    ///
    /// Comparing against ``appBundleIdentifier`` instead would be self-defeating:
    /// see ``officialBundleIdentifier``'s doc comment for exactly why. Comparing
    /// against this fixed constant instead means a fork answers `false` here no
    /// matter what it did to ``appBundleIdentifier`` — the two constants are
    /// intentionally independent, one fork-changeable, one not.
    public static func isRunningAsOfficialBuild(
        _ bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        bundleIdentifier == officialBundleIdentifier
    }

    /// Overrides which identifier ``applicationSupport()`` resolves to, for the rest
    /// of the process's lifetime. `nil` (the default) means "use
    /// `Bundle.main.bundleIdentifier`, as always."
    ///
    /// Exists for exactly one caller: `CheerioApp.init()`, when
    /// `BundleIdentifierMigration.migrateIfNeeded()` fails to move the old container
    /// forward. Redirecting only the SwiftData store to the old location would not be
    /// enough on its own — every meeting's audio and every enrolled speaker's sample
    /// is a path *relative to this container*, resolved through
    /// ``applicationSupport()`` by every caller in this file, `MeetingAudioRecorder`,
    /// and `AudioRetention`. Leaving those pointed at the (empty) new container while
    /// only the store falls back would reproduce the exact "empty library" problem
    /// this migration exists to prevent — just moved from the store into the audio
    /// lookups. Overriding here, once, keeps every caller consistent for the launch.
    ///
    /// A `Mutex`, not a plain `var`: this is written at most once, from
    /// `CheerioApp.init()`, before `CaptureSession`, `AppUpdater`, or the
    /// `ModelContainer` exist to read it — but Swift 6 has no way to know that from
    /// the call site, and a bare global `var` would be a real, not just theoretical,
    /// data race under strict concurrency. The lock is what makes this genuinely
    /// `Sendable`, not an `@unchecked` promise standing in for one.
    private static let containerOverride = Mutex<String?>(nil)

    /// Sets the override described above. Safe to call more than once — a second
    /// launch after a failed migration calls it again with the same value — but never
    /// call it after any code below has already read ``applicationSupport()``.
    public static func setContainerOverride(_ bundleIdentifier: String?) {
        containerOverride.withLock { $0 = bundleIdentifier }
    }

    private static func resolvedBundleIdentifier() -> String {
        containerOverride.withLock { $0 } ?? Bundle.main.bundleIdentifier ?? appBundleIdentifier
    }

    /// The shared, user-level Application Support directory — NOT where we write.
    /// Only used to migrate data written there before this was fixed.
    ///
    /// `create: false`: every caller (`BundleIdentifierMigration`,
    /// `StorageMigration`) uses this to build a path to check or move, never to
    /// write directly against, so there is nothing here for this resolution step
    /// itself to bring into being — see ``containerURL(bundleIdentifier:)``'s doc
    /// comment for why a path-resolution function creating something as a side
    /// effect is exactly the shape of bug issue #126 was.
    static func sharedApplicationSupport() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
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
            .appending(path: resolvedBundleIdentifier(), directoryHint: .isDirectory)
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

    /// Where every meeting's audio directory lives, without creating it —
    /// `AudioOrphanSweep` needs to be able to tell "nothing has recorded audio
    /// yet" apart from "the folder is missing," and creating it just to list it
    /// would erase that distinction.
    public static func meetingsDirectoryURL() throws -> URL {
        try applicationSupport().appending(path: meetingsFolder, directoryHint: .isDirectory)
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
