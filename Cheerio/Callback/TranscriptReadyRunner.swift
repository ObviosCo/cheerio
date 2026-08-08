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

    /// Last few lines of stderr kept for the log — enough to see why a command
    /// failed without holding onto everything it printed.
    private static let stderrTailLineLimit = 20

    /// Fires the callback for `export` if the current settings say to. Called from
    /// `CaptureSession` at the one point a meeting counts as "ready" — see the
    /// comment there for why that point and not earlier. Returns immediately: the
    /// subprocess runs on its own detached task, and nothing in the capture
    /// pipeline waits on it.
    static func fireIfNeeded(export: MeetingExport) {
        guard TranscriptCallbackSettings.shouldFire(for: export.kind),
            let command = TranscriptCallbackSettings.command
        else { return }
        fire(command: command, export: export)
    }

    /// Runs unconditionally, ignoring the scope setting. Backs Settings' "Run now
    /// on last meeting" button, whose entire point is to test a command regardless
    /// of what scope it's currently set to.
    static func fireForTest(command: String, export: MeetingExport) {
        fire(command: command, export: export)
    }

    private static func fire(command: String, export: MeetingExport) {
        // Identifies this invocation to the shared status object. Runs are detached
        // and can overlap, so a result has to say which run it came from — see
        // `TranscriptCallbackStatus.currentRunID` for the last-started-wins rule
        // that stops a slow earlier run from reporting over a newer one.
        let runID = UUID()
        Task.detached(priority: .utility) {
            await MainActor.run { TranscriptCallbackStatus.shared.markRunning(runID: runID, title: export.title) }
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
        // inert bytes in an env value or a file a script chooses to read.
        process.arguments = ["-c", command]
        // A sensible default working directory for a command that has no shell
        // session to inherit one from.
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        var environment = ProcessInfo.processInfo.environment
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

        let timedOut = await raceAgainstTimeout(waiter: waiter, process: process, timeout: timeout)
        if timedOut {
            log.error("Transcript-ready callback exceeded its timeout; terminating")
            process.terminate()
        }

        // Bounded even in the worst case: if the command ignores SIGTERM outright,
        // this gives up on the tail after a few more seconds rather than leaving
        // an orphaned task waiting on a pipe that may never close.
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

    /// Races `process`'s own completion against `timeout` and reports which one
    /// won. `process.terminate()` is called from *inside* the race, not after it
    /// returns: `withTaskGroup` waits for every child task to finish before
    /// returning, including the one awaiting `waiter`, so sending SIGTERM only
    /// after the group returns would be too late for the signal to unblock it.
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
            let timedOut = await group.next() ?? true
            if timedOut {
                process.terminate()
            }
            group.cancelAll()
            return timedOut
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
