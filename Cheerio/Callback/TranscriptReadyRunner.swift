import CheerioKit
import Foundation
import OSLog

/// Runs the user-configured "transcript ready" command from issue #26.
///
/// `Process` lives in the app target, not `CheerioKit`: the epic (#22) plans a
/// bundled MCP server that also links `CheerioKit`, and a portable module has no
/// business spawning subprocesses. `CallbackPayload` (in `CheerioKit`) builds
/// everything the command needs — the environment entries and the export file —
/// this only runs it.
enum TranscriptReadyRunner {
    private static let log = Logger(subsystem: "app.cheerio.mac", category: "TranscriptReadyRunner")

    /// How long a callback gets before it's terminated. Generous on purpose: the
    /// command might be `claude -p` or similar doing real agentic work against the
    /// transcript, and a couple of minutes of thinking is a normal outcome, not a
    /// hang.
    private static let timeout: Duration = .seconds(300)

    /// How long a timed-out command gets to honour SIGTERM before it's killed
    /// outright. Long enough for a shell script to run a trap and clean up, short
    /// enough that the status line doesn't sit at "Running…" while nothing happens.
    private static let terminationGracePeriod: Duration = .seconds(10)

    /// Last few lines of stderr kept for the log — enough to see why a command
    /// failed without holding onto everything it printed.
    private static let stderrTailLineLimit = 20

    /// Appended to the child's inherited `PATH`.
    ///
    /// A GUI app launched from Finder inherits launchd's minimal `PATH`
    /// (`/usr/bin:/bin:/usr/sbin:/sbin`), and `/bin/zsh -c` — deliberately not
    /// `-l`, see `run` — never sources the user's profile. So `claude -p …`, or
    /// anything else installed by Homebrew, npm, pipx, or uv, wouldn't resolve at
    /// all: the command would fail with "command not found" for reasons that have
    /// nothing to do with what the user typed.
    ///
    /// Augmenting a known list beats sourcing a login shell to find out. A profile
    /// is arbitrary user code — slow, order-dependent, and free to fail or block —
    /// and running it would make the callback's environment differ from run to run
    /// for reasons this file can't see. These four directories are the same every
    /// time and visible right here. Anything installed somewhere else still works;
    /// give the command an absolute path.
    private static let additionalPathDirectories: [String] = [
        "/opt/homebrew/bin",  // Homebrew on Apple silicon
        "/opt/homebrew/sbin",
        "/usr/local/bin",  // Homebrew on Intel, plus most standalone installers
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
    ]

    /// Fires the callback for `export` if the current settings say to. Called from
    /// `CaptureSession` at the one point a meeting counts as "ready" — see the
    /// comment there for why that point and not earlier. Returns immediately: the
    /// subprocess runs on its own detached task, and nothing in the capture
    /// pipeline waits on it.
    @MainActor
    static func fireIfNeeded(export: MeetingExport) {
        guard TranscriptCallbackSettings.shouldFire(for: export.kind),
            let command = TranscriptCallbackSettings.command
        else { return }
        fire(command: command, export: export)
    }

    /// Runs unconditionally, ignoring the scope setting. Backs Settings' "Run now
    /// on last meeting" button, whose entire point is to test a command regardless
    /// of what scope it's currently set to.
    @MainActor
    static func fireForTest(command: String, export: MeetingExport) {
        fire(command: command, export: export)
    }

    /// `@MainActor` so the status claim below can happen synchronously; both callers
    /// are already on the main actor (`CaptureSession` is `@MainActor`, and Settings
    /// calls this from a button action).
    @MainActor
    private static func fire(command: String, export: MeetingExport) {
        // Identifies this invocation to the shared status object. Runs are detached
        // and can overlap, so a result has to say which run it came from — see
        // `TranscriptCallbackStatus.currentRunID` for the last-started-wins rule
        // that stops a slow earlier run from reporting over a newer one.
        //
        // Minted *and claimed* here, before `Task.detached`, and that ordering is
        // the whole point: claiming from inside the detached task left it up to the
        // scheduler, so two invocations started in one order could reach
        // `markRunning` in the other. The older run would then own the status line
        // and the newer one's result would be dropped as stale — precisely
        // backwards. Doing it synchronously makes "last started" mean what it says,
        // because the claim happens in the same main-actor turn as the call.
        let runID = UUID()
        TranscriptCallbackStatus.shared.markRunning(runID: runID, title: export.title)
        Task.detached(priority: .utility) {
            do {
                let payload = try CallbackPayload.prepare(export: export)
                switch await run(command: command, payload: payload) {
                case .success:
                    await MainActor.run {
                        TranscriptCallbackStatus.shared.markSucceeded(runID: runID, title: export.title)
                    }
                case .failure(let detail):
                    await MainActor.run {
                        TranscriptCallbackStatus.shared.markFailed(runID: runID, title: export.title, detail: detail)
                    }
                }
            } catch {
                log.error("Transcript-ready callback couldn't prepare its payload: \(error, privacy: .public)")
                let detail = "Couldn't prepare payload: \(error.localizedDescription)"
                await MainActor.run {
                    TranscriptCallbackStatus.shared.markFailed(runID: runID, title: export.title, detail: detail)
                }
            }
        }
    }

    private enum RunResult {
        case success
        case failure(String)
    }

    private static func run(command: String, payload: CallbackPayload.Prepared) async -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // `-c`, never `-l`: runs exactly the string the user typed, without
        // sourcing their login shell config. That string is the *only* thing the
        // shell parses — every meeting-specific value travels via `environment`,
        // stdin, or the file at `CHEERIO_EXPORT_PATH`, never appended to
        // `arguments`. A transcript containing something that looks like shell
        // syntax can't reach the parser this way; it can only ever show up as
        // inert bytes in an env value or a file a script chooses to read. The cost of
        // skipping the profile is that tool locations have to come from somewhere
        // else — see ``additionalPathDirectories``.
        process.arguments = ["-c", command]
        // A sensible default working directory for a command that has no shell
        // session to inherit one from.
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = augmentedPath(inheriting: environment["PATH"])
        for (key, value) in payload.environment { environment[key] = value }
        process.environment = environment

        let stdinPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        // Not inherited: a subprocess's stdout has nowhere sensible to go in a
        // GUI app, and the contract only asks for exit status plus a stderr tail.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        let waiter = ProcessWaiter()
        // Set before `run()`, not after: a process that exits immediately must
        // not be able to fire its termination callback before anything is
        // listening for it.
        process.terminationHandler = { [waiter] _ in
            Task { await waiter.finish() }
        }

        do {
            try process.run()
        } catch {
            log.error("Couldn't launch the transcript-ready callback: \(error, privacy: .public)")
            return .failure("Couldn't launch: \(error.localizedDescription)")
        }

        // Drained concurrently, not just after exit: macOS's default pipe buffer
        // is 64KB, and a command that writes more than that to stderr while
        // nobody's reading would deadlock against the process we're waiting on
        // below. Only the tail is kept — that's all a "stderr tail" needs to be.
        let stderrTailTask = Task.detached(priority: .utility) { () -> [String] in
            var tail: [String] = []
            do {
                for try await line in stderrPipe.fileHandleForReading.bytes.lines {
                    tail.append(line)
                    if tail.count > stderrTailLineLimit {
                        tail.removeFirst(tail.count - stderrTailLineLimit)
                    }
                }
            } catch {
                // Cancelled or torn down early — whatever was collected already is
                // still a useful tail.
            }
            return tail
        }

        // Also off to the side: a command that doesn't read stdin promptly would
        // otherwise block this function before the timeout race even starts,
        // since writing to a full pipe blocks the calling thread. If the command
        // never reads it, the write eventually fails with a broken pipe once the
        // process exits and closes its end.
        Task.detached(priority: .utility) {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: payload.jsonData)
            try? stdinPipe.fileHandleForWriting.close()
        }

        // Returns only once the process is actually gone — see `raceAgainstTimeout`
        // for how the SIGTERM-then-SIGKILL escalation guarantees that — so
        // `terminationStatus` below is safe to read either way.
        let timedOut = await raceAgainstTimeout(waiter: waiter, process: process, timeout: timeout)

        // Bounded even in the worst case: the process is gone by now, but a
        // grandchild it left behind can still hold the write end of this pipe open,
        // so give up on the tail after a few seconds rather than leaving an orphaned
        // task waiting on a pipe that may never close.
        let tail = await withTimeout(.seconds(5), cancelling: stderrTailTask)

        let status = process.terminationStatus
        if timedOut {
            return .failure("Timed out and was terminated")
        }
        if status == 0 {
            log.notice(
                "Transcript-ready callback for \(payload.environment["CHEERIO_MEETING_ID"] ?? "?", privacy: .public) finished"
            )
            return .success
        }
        let tailText = tail.joined(separator: "\n")
        log.error("Transcript-ready callback exited \(status, privacy: .public): \(tailText, privacy: .public)")
        return .failure(tailText.isEmpty ? "Exited with status \(status)" : tailText)
    }

    /// The child's `PATH`: whatever this app inherited, plus
    /// ``additionalPathDirectories`` for the ones that aren't already on it. Appended
    /// rather than prepended, so nothing here can shadow a directory the inherited
    /// path already prefers. Falls back to the standard system directories if the app
    /// somehow inherited no `PATH` at all, which would otherwise leave the command
    /// unable to find even `ls`.
    private static func augmentedPath(inheriting inherited: String?) -> String {
        var components = (inherited ?? "").split(separator: ":").map(String.init)
        if components.isEmpty {
            components = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        }
        var seen = Set(components)
        for directory in additionalPathDirectories where seen.insert(directory).inserted {
            components.append(directory)
        }
        return components.joined(separator: ":")
    }

    /// Races `process`'s own completion against `timeout` and reports which one won,
    /// returning only once the process has actually exited.
    ///
    /// Signals are sent from *inside* the race, not after it returns: `withTaskGroup`
    /// waits for every child task to finish before returning, including the one
    /// awaiting `waiter`, and `waiter.wait()` can't be cancelled out of — it's
    /// waiting on `terminationHandler`. Anything that unblocks it therefore has to
    /// happen before the closure returns.
    ///
    /// Which is also why SIGTERM alone isn't enough. A command that installs a
    /// handler for it, or ignores it outright, keeps running; `terminationHandler`
    /// never fires, the continuation never resumes, and the group — and with it the
    /// runner and the status line — sits at "Running…" forever. So SIGTERM gets a
    /// grace period and then SIGKILL, which cannot be caught, blocked, or ignored.
    /// That makes the process's death, and so the waiter's resumption, guaranteed.
    private static func raceAgainstTimeout(waiter: ProcessWaiter, process: Process, timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await waiter.wait()
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return true
            }
            guard await group.next() == true else {
                // Exited on its own; only the sleep is left to cancel.
                group.cancelAll()
                return false
            }

            log.error("Transcript-ready callback exceeded its timeout; terminating")
            process.terminate()

            // The grace period is awaited here in the group's own body rather than in
            // another child task, because `Process` isn't `Sendable` and so can't
            // cross into one — and it's polled rather than slept through in one go, so
            // a command that *does* honour SIGTERM doesn't hold this open for the full
            // ten seconds after it's already gone.
            //
            // Cancellation ends the grace early and goes straight to the kill below:
            // a cancelled sleep returns immediately, so waiting it out would just
            // spin, and if we're being torn down the one thing that matters is that
            // the process definitely dies.
            let deadline = ContinuousClock.now.advanced(by: terminationGracePeriod)
            while process.isRunning, ContinuousClock.now < deadline, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning {
                log.error("Transcript-ready callback ignored SIGTERM; sending SIGKILL")
                kill(process.processIdentifier, SIGKILL)
            }

            // No `cancelAll()`: the only child left is the waiter, and cancelling
            // can't unblock it anyway. It resumes when `terminationHandler` fires,
            // which the signals above have now made certain.
            return true
        }
    }

    /// Awaits `task`, giving up and cancelling it after `timeout` — used so a
    /// stalled read can't leave this function (and the callback pipeline it's
    /// part of) waiting forever.
    private static func withTimeout(_ timeout: Duration, cancelling task: Task<[String], Never>) async -> [String] {
        await withTaskGroup(of: [String]?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            task.cancel()
            group.cancelAll()
            return first ?? []
        }
    }
}

/// Bridges `Process.terminationHandler`'s callback-based API into `async`/`await`.
/// An actor because the handler fires on whatever queue `Process` chooses to call
/// it on, not necessarily the task that's awaiting `wait()`.
private actor ProcessWaiter {
    private var isFinished = false
    private var continuation: CheckedContinuation<Void, Never>?

    func finish() {
        isFinished = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        if isFinished { return }
        await withCheckedContinuation { continuation = $0 }
    }
}
