import Darwin
import Foundation

/// A child process spawned into a **process group of its own**, with its standard
/// streams wired to this process.
///
/// `Foundation.Process` would be the obvious tool, and it can't do the one thing
/// this type exists for. `Process` always leaves the child in *this* app's process
/// group, and it exposes only the child's own pid — so terminating a timed-out
/// callback signals the `/bin/zsh` that ran the command and nothing else. A
/// pipeline or a compound command (`claude -p … | tee log`, or anything that
/// spawns an agent CLI) leaves descendants behind that outlive the shell: they
/// keep running long past the timeout, and because they inherited the stdin and
/// stderr pipes, the stderr-tail reader never sees EOF either. The timeout stops
/// meaning anything.
///
/// Putting the child in a new group from the parent side doesn't work: a parent
/// `setpgid` races the child's `exec` and starts failing with `EACCES` the moment
/// `zsh` has exec'd, which is not fixable from outside. `posix_spawn` with
/// `POSIX_SPAWN_SETPGROUP` makes the child a group leader *atomically at spawn*,
/// so there's no window at all — and then one `killpg` reaches the shell and every
/// descendant that hasn't deliberately left the group.
struct CallbackProcess: Sendable {
    /// The child's pid — which, because it was spawned as a group leader, is also
    /// its process *group* id. That's why ``signalGroup(_:)`` can pass it straight
    /// to `killpg`.
    let processIdentifier: pid_t
    /// This process's end of the child's stdin. Closing it is what gives the child
    /// EOF.
    let standardInput: FileHandle
    /// This process's end of the child's stderr. Reads until every process in the
    /// group has closed its copy — which, for a command that leaves descendants
    /// running, only happens once the group is signalled, and for one that left the
    /// group behind may never happen at all. Handed straight to
    /// `StderrTailReader`, which takes ownership of the descriptor and closes this
    /// handle; nothing else should read from it.
    let standardError: FileHandle

    struct SpawnError: Error, LocalizedError {
        /// Which call reported the failure — `posix_spawn` itself, or one of the
        /// setup calls that build its arguments. Named because "Invalid argument"
        /// on its own says nothing about *which* argument, and these are the only
        /// errors a user ever sees from a callback that wouldn't start.
        let call: String
        let code: Int32
        var errorDescription: String? { "\(call): \(String(cString: strerror(code)))" }
    }

    /// Sends `signal` to the child's entire process group, never to the child
    /// alone. `ESRCH` is the expected answer once the group is empty, so the result
    /// is deliberately discarded.
    ///
    /// Reaping the child frees its pid, and an empty group's id along with it — but
    /// a group id stays reserved while the group still has members, so as long as
    /// anything in there is alive this still means *this* group.
    func signalGroup(_ signal: Int32) {
        _ = killpg(processIdentifier, signal)
    }

    /// Whether anything in the child's process group is still around. Signal 0 is
    /// delivered to nobody and reports only whether there was somebody to deliver
    /// it to.
    ///
    /// Note the child itself counts until it has been *reaped*: a zombie is still a
    /// member of its group. So this answers "is the tree gone" only once the child's
    /// own status has been collected.
    var groupIsAlive: Bool {
        killpg(processIdentifier, 0) == 0
    }

    /// Launches `executablePath`, with stdin and stderr on pipes, stdout on
    /// `/dev/null`, and the child leading a new process group.
    ///
    /// The caller owns the child from here: it must be reaped (see
    /// ``ExitStatus``), and nothing else in the process will do that for it.
    ///
    /// Throws ``SpawnError`` if the launch fails *or* if any of the calls that
    /// describe it does — an unrecorded action would otherwise let `posix_spawn`
    /// succeed against a child that isn't the one this function promises. Nothing is
    /// left open on a throw.
    static func spawn(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String
    ) throws -> CallbackProcess {
        // Every `posix_spawn*` call reports failure by *returning* the errno rather
        // than setting it, so a zero return is the only thing that means "recorded".
        func check(_ returnCode: Int32, _ call: String) throws {
            guard returnCode == 0 else { throw SpawnError(call: call, code: returnCode) }
        }
        // The libc calls that follow the usual `-1`-and-`errno` convention instead.
        func checkErrno(_ returnCode: Int32, _ call: String) throws {
            guard returnCode != -1 else { throw SpawnError(call: call, code: errno) }
        }

        let stdinPipe = Pipe()
        let stderrPipe = Pipe()

        // The child inherits every descriptor that isn't close-on-exec, including
        // the *parent* ends of both pipes — and a child holding its own copy of the
        // stdin write end would never see EOF when this process closes it. Marking
        // all four is enough: `adddup2` clears the flag on the two copies that
        // become the child's fds 0 and 2, and everything else goes away at exec.
        let pipeHandles = [
            stdinPipe.fileHandleForReading, stdinPipe.fileHandleForWriting,
            stderrPipe.fileHandleForReading, stderrPipe.fileHandleForWriting,
        ]

        // Anything thrown below leaves this true, and every end this function opened
        // is closed on the way out — a caller that got an error has nothing to clean
        // up, and no descriptor leaks per failed callback. Cleared only once the
        // returned value owns the two parent ends. Double-closing is not a hazard:
        // `FileHandle.close()` clears its own descriptor, so the two child ends
        // closed explicitly after the spawn are no-ops here.
        var ownsPipeEnds = true
        defer {
            if ownsPipeEnds {
                for handle in pipeHandles { try? handle.close() }
            }
        }

        for handle in pipeHandles {
            // Not cosmetic: a child that inherited the stdin *write* end would never
            // see EOF, and one that inherited the stderr *read* end would keep the
            // tail reader from ever seeing it. Both hang the runner, so a failure
            // here has to stop the launch rather than be papered over.
            try checkErrno(fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC), "fcntl(F_SETFD, FD_CLOEXEC)")
        }

        // Each setup call below can fail on its own account — `ENOMEM` growing the
        // action list, `EBADF` for a descriptor that isn't open, `EINVAL` for a flag
        // this platform doesn't know — and a failure is silent: the action simply
        // isn't recorded. `posix_spawn` then succeeds against an incomplete
        // description, launching a child with, say, no stdin pipe, or in the wrong
        // directory, or in *this* process's group, where the timeout's `killpg` would
        // signal the app itself. So every one of them is checked before spawning.
        var fileActions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&fileActions), "posix_spawn_file_actions_init")
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        try check(
            posix_spawn_file_actions_adddup2(&fileActions, stdinPipe.fileHandleForReading.fileDescriptor, 0),
            "posix_spawn_file_actions_adddup2(stdin)"
        )
        // Not inherited: a subprocess's stdout has nowhere sensible to go in a GUI
        // app, and the contract only asks for exit status plus a stderr tail.
        try check(
            posix_spawn_file_actions_addopen(&fileActions, 1, "/dev/null", O_WRONLY, 0),
            "posix_spawn_file_actions_addopen(/dev/null)"
        )
        try check(
            posix_spawn_file_actions_adddup2(&fileActions, stderrPipe.fileHandleForWriting.fileDescriptor, 2),
            "posix_spawn_file_actions_adddup2(stderr)"
        )
        // A sensible default working directory for a command that has no shell
        // session to inherit one from.
        try check(
            posix_spawn_file_actions_addchdir(&fileActions, workingDirectory),
            "posix_spawn_file_actions_addchdir"
        )

        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes), "posix_spawnattr_init")
        defer { posix_spawnattr_destroy(&attributes) }
        // A pgroup of 0 means "your own pid": the child becomes the leader of a
        // brand-new group, which is the entire reason this file exists.
        try check(posix_spawnattr_setpgroup(&attributes, 0), "posix_spawnattr_setpgroup")
        // Signal state is inherited across exec, and this app's is not the user
        // command's business. An inherited `SIG_IGN` for `SIGPIPE` (Foundation sets
        // one) would stop `… | head` behaving the way the user expects, and — worse
        // for this file — an inherited *blocked* `SIGTERM` would leave the timeout's
        // polite phase pending instead of delivered, turning every timeout into a
        // full ten-second wait for the `SIGKILL`. So: default dispositions, empty
        // mask, same as `Process` does.
        var allSignals = sigset_t()
        try checkErrno(sigfillset(&allSignals), "sigfillset")
        try check(posix_spawnattr_setsigdefault(&attributes, &allSignals), "posix_spawnattr_setsigdefault")
        var noSignals = sigset_t()
        try checkErrno(sigemptyset(&noSignals), "sigemptyset")
        try check(posix_spawnattr_setsigmask(&attributes, &noSignals), "posix_spawnattr_setsigmask")
        try check(
            posix_spawnattr_setflags(
                &attributes,
                Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
            ),
            "posix_spawnattr_setflags"
        )

        var argv: [UnsafeMutablePointer<CChar>?] = ([executablePath] + arguments).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, executablePath, &fileActions, &attributes, argv, envp)

        // The child has its own copies now, and this process has to let go of the ends
        // it doesn't use: for as long as it holds the stderr *write* end, a reader on
        // the other side can never see EOF, no matter what happens to the child.
        try? stdinPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForWriting.close()
        // The two parent ends are left to the `defer` above on this path.
        guard result == 0 else { throw SpawnError(call: "posix_spawn", code: result) }
        ownsPipeEnds = false
        return CallbackProcess(
            processIdentifier: pid,
            standardInput: stdinPipe.fileHandleForWriting,
            standardError: stderrPipe.fileHandleForReading
        )
    }
}

extension CallbackProcess {
    /// How a child ended, decoded from a raw `waitpid` status.
    enum ExitStatus: Sendable, Equatable {
        case exited(Int32)
        case signalled(Int32)
        /// `waitpid` reported something this code doesn't ask about — a stopped
        /// child, or a failure to reap at all. Treated as a failure with no status
        /// rather than silently as success.
        case unknown

        /// `<sys/wait.h>`'s `WIFEXITED`/`WEXITSTATUS`/`WTERMSIG` are C macros, so
        /// they're invisible from Swift; this is the same bit layout spelled out.
        init(rawStatus: Int32) {
            let signalBits = rawStatus & 0x7f
            switch signalBits {
            case 0: self = .exited((rawStatus >> 8) & 0xff)
            case 0x7f: self = .unknown  // stopped, which needs `WUNTRACED` we never pass
            default: self = .signalled(signalBits)
            }
        }
    }
}
