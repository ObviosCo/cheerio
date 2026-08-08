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
    /// running, only happens once the group is signalled.
    let standardError: FileHandle

    struct SpawnError: Error, LocalizedError {
        let code: Int32
        var errorDescription: String? { String(cString: strerror(code)) }
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
    static func spawn(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String
    ) throws -> CallbackProcess {
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
        for handle in pipeHandles {
            _ = fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC)
        }

        // The setup calls below return their own error codes, deliberately unchecked:
        // they only record what to do, and anything actually wrong with what they
        // recorded — a closed descriptor, an unreachable working directory, no
        // `/dev/null` — comes back from `posix_spawn` itself as the errno this throws.
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_adddup2(&fileActions, stdinPipe.fileHandleForReading.fileDescriptor, 0)
        // Not inherited: a subprocess's stdout has nowhere sensible to go in a GUI
        // app, and the contract only asks for exit status plus a stderr tail.
        posix_spawn_file_actions_addopen(&fileActions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, stderrPipe.fileHandleForWriting.fileDescriptor, 2)
        // A sensible default working directory for a command that has no shell
        // session to inherit one from.
        posix_spawn_file_actions_addchdir(&fileActions, workingDirectory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A pgroup of 0 means "your own pid": the child becomes the leader of a
        // brand-new group, which is the entire reason this file exists.
        posix_spawnattr_setpgroup(&attributes, 0)
        // Signal state is inherited across exec, and this app's is not the user
        // command's business. An inherited `SIG_IGN` for `SIGPIPE` (Foundation sets
        // one) would stop `… | head` behaving the way the user expects, and — worse
        // for this file — an inherited *blocked* `SIGTERM` would leave the timeout's
        // polite phase pending instead of delivered, turning every timeout into a
        // full ten-second wait for the `SIGKILL`. So: default dispositions, empty
        // mask, same as `Process` does.
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
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
        guard result == 0 else {
            try? stdinPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForReading.close()
            throw SpawnError(code: result)
        }
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
