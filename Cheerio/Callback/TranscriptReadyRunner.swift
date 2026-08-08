import CheerioKit
import Darwin
import Dispatch
import Foundation
import OSLog

/// Runs the user-configured "transcript ready" command from issue #26.
///
/// Subprocess spawning lives in the app target, not `CheerioKit`: the epic (#22)
/// plans a bundled MCP server that also links `CheerioKit`, and a portable module
/// has no business spawning subprocesses. `CallbackPayload` (in `CheerioKit`)
/// builds everything the command needs — the environment entries and the export
/// file — this only runs it. `CallbackProcess` next door handles the launch, and
/// explains why it isn't `Foundation.Process`.
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
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = augmentedPath(inheriting: environment["PATH"])
        for (key, value) in payload.environment { environment[key] = value }

        let child: CallbackProcess
        do {
            child = try CallbackProcess.spawn(
                executablePath: "/bin/zsh",
                // `-c`, never `-l`: runs exactly the string the user typed, without
                // sourcing their login shell config. That string is the *only* thing the
                // shell parses — every meeting-specific value travels via the
                // environment, stdin, or the file at `CHEERIO_EXPORT_PATH`, never
                // appended to the argument list. A transcript containing something that
                // looks like shell syntax can't reach the parser this way; it can only
                // ever show up as inert bytes in an env value or a file a script chooses
                // to read. The cost of skipping the profile is that tool locations have
                // to come from somewhere else — see ``additionalPathDirectories``.
                arguments: ["-c", command],
                environment: environment,
                workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path
            )
        } catch {
            log.error("Couldn't launch the transcript-ready callback: \(error, privacy: .public)")
            return .failure("Couldn't launch: \(error.localizedDescription)")
        }
        let pid = child.processIdentifier

        let waiter = ProcessWaiter()
        // What `Process.terminationHandler` used to provide, on a pid this file owns
        // outright. The source has to be cancelled before it's released — libdispatch
        // traps on the release of a still-active source — hence the `defer`, which
        // also keeps it alive across every `await` below.
        let exitSource = DispatchSource.makeProcessSource(
            identifier: pid,
            eventMask: .exit,
            queue: .global(qos: .utility)
        )
        exitSource.setEventHandler { Task { await waiter.hasExited(reaping: pid) } }
        defer { exitSource.cancel() }
        exitSource.activate()
        // Arming can lose a race `Process` handled internally: a command that exits
        // immediately may already be a zombie by now, and a `.exit` source isn't
        // guaranteed to fire for a child that was gone before it went live. One
        // non-blocking check closes that window — reaping is idempotent, so whichever
        // of the two paths gets there first records the status and the other no-ops.
        await waiter.hasExited(reaping: pid)

        // Drained concurrently, not just after exit: macOS's default pipe buffer
        // is 64KB, and a command that writes more than that to stderr while
        // nobody's reading would deadlock against the process we're waiting on
        // below. Only the tail is kept — that's all a "stderr tail" needs to be.
        let stderrHandle = child.standardError
        let stderrTailTask = Task.detached(priority: .utility) { () -> [String] in
            var tail: [String] = []
            do {
                for try await line in stderrHandle.bytes.lines {
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
        // never reads it, the write eventually fails with a broken pipe once every
        // process in the group has exited and closed its end.
        let stdinHandle = child.standardInput
        Task.detached(priority: .utility) {
            try? stdinHandle.write(contentsOf: payload.jsonData)
            try? stdinHandle.close()
        }

        // Returns only once the command is actually gone — see `raceAgainstTimeout`
        // for how the SIGTERM-then-SIGKILL escalation guarantees that — so the
        // waiter's status below is populated either way.
        let timedOut = await raceAgainstTimeout(waiter: waiter, child: child, timeout: timeout)

        // Bounded even so: the escalation kills the whole process group, which closes
        // every copy of this pipe and ends the read — but a descendant that
        // deliberately left the group (`setsid`, a daemon) could still be holding one,
        // so give up on the tail after a few seconds rather than leaving an orphaned
        // task waiting on a pipe that may never close.
        let tail = await withTimeout(.seconds(5), cancelling: stderrTailTask)

        if timedOut {
            return .failure("Timed out and was terminated")
        }
        // A death by SIGTERM or SIGKILL is a timed-out command, and it's already been
        // reported as one above — so a signal reaching this switch means the command
        // died on its own account (a crash, or somebody else's `kill`), which is a
        // failure with no exit code rather than an absent one.
        let detail: String
        switch await waiter.exitStatus {
        case .exited(0):
            log.notice(
                "Transcript-ready callback for \(payload.environment["CHEERIO_MEETING_ID"] ?? "?", privacy: .public) finished"
            )
            return .success
        case .exited(let code):
            detail = "Exited with status \(code)"
        case .signalled(let signal):
            detail = "Killed by signal \(signal)"
        case .unknown, nil:
            detail = "Exited with an indeterminate status"
        }
        let tailText = tail.joined(separator: "\n")
        log.error("Transcript-ready callback failed — \(detail, privacy: .public): \(tailText, privacy: .public)")
        return .failure(tailText.isEmpty ? detail : tailText)
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

    /// Races `child`'s own completion against `timeout` and reports which one won,
    /// returning only once the command has actually exited.
    ///
    /// Signals are sent from *inside* the race, not after it returns: `withTaskGroup`
    /// waits for every child task to finish before returning, including the one
    /// awaiting `waiter`, and `waiter.wait()` can't be cancelled out of — it's
    /// waiting on the child's exit. Anything that unblocks it therefore has to happen
    /// before the closure returns.
    ///
    /// Which is also why SIGTERM alone isn't enough. A command that installs a
    /// handler for it, or ignores it outright, keeps running; the exit never comes,
    /// the continuation never resumes, and the group — and with it the runner and the
    /// status line — sits at "Running…" forever. So SIGTERM gets a grace period and
    /// then SIGKILL, which cannot be caught, blocked, or ignored. That makes the
    /// command's death, and so the waiter's resumption, guaranteed.
    ///
    /// Every signal goes to the whole process *group* (see ``CallbackProcess``).
    /// Signalling the shell alone would leave a pipeline's other half, or an agent
    /// CLI it started, running past the timeout — still holding the stderr pipe, so
    /// even the tail collection would stall on it.
    private static func raceAgainstTimeout(waiter: ProcessWaiter, child: CallbackProcess, timeout: Duration) async -> Bool {
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

            log.error("Transcript-ready callback exceeded its timeout; terminating its process group")
            child.signalGroup(SIGTERM)

            // The grace period is awaited here in the group's own body rather than in
            // another child task because nothing has to run alongside it: the group
            // can't return until the waiter's task finishes anyway. And it's polled
            // rather than slept through in one go, so a tree that *does* honour SIGTERM
            // doesn't hold this open for the full ten seconds after it's already gone.
            //
            // The poll asks the waiter instead of `kill(pid, 0)`, which can't answer
            // the question: an exited-but-unreaped child is a zombie, and signalling a
            // zombie succeeds, so `kill` reads the same either way. A non-blocking
            // `waitpid` distinguishes them, and reaps while it's there — which is also
            // what lets `groupIsAlive` then mean "descendants are still shutting down"
            // rather than "the child hasn't been collected yet".
            //
            // Cancellation ends the grace early and goes straight to the kill below:
            // a cancelled sleep returns immediately, so waiting it out would just
            // spin, and if we're being torn down the one thing that matters is that
            // the tree definitely dies.
            let deadline = ContinuousClock.now.advanced(by: terminationGracePeriod)
            while ContinuousClock.now < deadline, !Task.isCancelled {
                if await waiter.hasExited(reaping: child.processIdentifier), !child.groupIsAlive { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if await !waiter.hasExited(reaping: child.processIdentifier) {
                log.error("Transcript-ready callback ignored SIGTERM; SIGKILLing its process group")
            } else if child.groupIsAlive {
                log.error("Transcript-ready callback exited but left the rest of its group running; SIGKILLing it")
            }
            // Sent unconditionally, even when the shell itself went quietly: the shell
            // dying doesn't take a pipeline's other half or a spawned CLI with it, and
            // those are exactly the processes that would otherwise outlive the timeout.
            // Harmless when there's nothing left — `killpg` just reports `ESRCH`.
            child.signalGroup(SIGKILL)

            // No `cancelAll()`: the only child task left is the waiter, and cancelling
            // can't unblock it anyway. It resumes when the command is reaped, which the
            // signals above have now made certain.
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

/// Bridges a child's exit — the `DispatchSourceProcess` callback, plus the
/// `waitpid` that collects its status — into `async`/`await`.
///
/// An actor for two reasons. The dispatch source's handler fires on its own queue,
/// not the task awaiting ``wait()``; and the `waitpid` has to happen exactly once,
/// while two callers race for it (the handler, and the check right after the source
/// is armed that covers a child which exited before it went live). A second
/// `waitpid` for an already-reaped pid fails with `ECHILD` and loses the status, so
/// serialising it here is what makes "whoever gets there first" safe.
private actor ProcessWaiter {
    /// The child's status once it's been reaped, `nil` until then.
    private(set) var exitStatus: CallbackProcess.ExitStatus?
    private var continuation: CheckedContinuation<Void, Never>?

    /// Reaps `pid` if it has exited, resuming ``wait()`` if it had, and reports
    /// whether it's gone. Safe — and expected — to call repeatedly.
    @discardableResult
    func hasExited(reaping pid: pid_t) -> Bool {
        if exitStatus != nil { return true }
        var rawStatus: Int32 = 0
        let result = waitpid(pid, &rawStatus, WNOHANG)
        if result == 0 { return false }
        // A negative result means `waitpid` itself failed, which for a child this
        // process owns and reaps in exactly one place shouldn't happen. Reporting
        // "still running" forever on the strength of an unexplained `ECHILD` would
        // hang the runner, so call it gone with a status nobody can read.
        exitStatus = result == pid ? CallbackProcess.ExitStatus(rawStatus: rawStatus) : .unknown
        continuation?.resume()
        continuation = nil
        return true
    }

    func wait() async {
        if exitStatus != nil { return }
        await withCheckedContinuation { continuation = $0 }
    }
}
