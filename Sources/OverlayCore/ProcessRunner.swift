import Darwin
import Foundation

public struct RunLimits {
    public var timeout: Double = 10
    public var maxStdout = 1 << 20
    /// After the direct child exits, how long leftover group members may keep the pipes open.
    public var drainGrace: Double = 0.2
    /// Between SIGTERM and SIGKILL of the process group.
    public var killGrace: Double = 1

    public init() {}
}

public enum RunOutcome: Equatable {
    /// stderr content is never kept; only its size.
    case exited(Int32, stdout: Data, stderrBytes: Int)
    case signaled(Int32)
    case timedOut, oversized, cancelled
    case spawnFailed(Int32)
}

/// Runs one child at a time in its own session (no controlling terminal, so ssh cannot prompt),
/// with stdin from /dev/null, bounded stdout, discarded stderr, a hard timeout and group cleanup.
public final class ProcessRunner {
    private let limits: RunLimits
    private let lock = NSLock()
    private var group: pid_t = 0
    private var cancelled = false

    /// Process group of the most recent child; for tests and diagnostics only.
    public private(set) var lastGroup: pid_t = 0

    public init(limits: RunLimits = RunLimits()) {
        self.limits = limits
    }

    /// Stops the current child, if any, and makes further runs return `.cancelled`.
    public func cancel() {
        lock.lock()
        cancelled = true
        // Signal only while the published group is protected from retirement and PID reuse.
        if group > 0 { kill(-group, SIGTERM) }
        lock.unlock()
    }

    /// Blocking. Call from a background queue only.
    public func run(_ arguments: [String]) -> RunOutcome {
        guard let executable = arguments.first else { return .spawnFailed(EINVAL) }
        var stdoutPipe: [Int32] = [-1, -1], stderrPipe: [Int32] = [-1, -1]
        guard pipe(&stdoutPipe) == 0 else { return .spawnFailed(errno) }
        guard pipe(&stderrPipe) == 0 else {
            let code = errno
            stdoutPipe.forEach { close($0) }
            return .spawnFailed(code)
        }
        for fd in stdoutPipe + stderrPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // CLOEXEC_DEFAULT: the child inherits only 0, 1 and 2.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                    | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var defaults = sigset_t(), mask = sigset_t()
        sigemptyset(&defaults)
        sigemptyset(&mask)
        for signal in [SIGPIPE, SIGHUP, SIGINT, SIGTERM, SIGCHLD] { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &mask)

        let argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let envp = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { envp.forEach { free($0) } }

        lock.lock()
        if cancelled {
            lock.unlock()
            (stdoutPipe + stderrPipe).forEach { close($0) }
            return .cancelled
        }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        if spawned == 0 {
            group = pid
            lastGroup = pid
        }
        lock.unlock()
        close(stdoutPipe[1])
        close(stderrPipe[1])
        guard spawned == 0 else {
            close(stdoutPipe[0])
            close(stderrPipe[0])
            return .spawnFailed(spawned)
        }
        return supervise(pid: pid, stdoutFD: stdoutPipe[0], stderrFD: stderrPipe[0])
    }

    private func supervise(pid: pid_t, stdoutFD: Int32, stderrFD: Int32) -> RunOutcome {
        var fds = [pollfd(fd: stdoutFD, events: Int16(POLLIN), revents: 0),
                   pollfd(fd: stderrFD, events: Int16(POLLIN), revents: 0)]
        defer {
            close(stdoutFD)
            close(stderrFD)
        }
        var stdout = Data(), stderrBytes = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let deadline = MonotonicClock.now() + seconds(limits.timeout)
        var exitedAt: UInt64?
        var failure: RunOutcome?

        while true {
            let now = MonotonicClock.now()
            if isCancelled { failure = .cancelled; break }
            if now >= deadline { failure = .timedOut; break }
            if exitedAt == nil, hasExited(pid) { exitedAt = now }
            if exitedAt != nil && fds.allSatisfy({ $0.fd < 0 }) { break }
            // Background members of the child's group may hold the pipes after the child exits.
            if let exitedAt, elapsed(since: exitedAt, now: now) > seconds(limits.drainGrace) { break }

            let wait = min(100, Int32((deadline - now) / 1_000_000) + 1)
            guard poll(&fds, nfds_t(fds.count), wait) >= 0 || errno == EINTR else { break }
            for index in fds.indices where fds[index].fd >= 0 && fds[index].revents != 0 {
                let count = read(fds[index].fd, &buffer, buffer.count)
                if count > 0 {
                    if index == 0 {
                        stdout.append(contentsOf: buffer[0..<count])
                    } else {
                        stderrBytes += count
                    }
                } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                    fds[index].fd = -1
                }
            }
            if stdout.count > limits.maxStdout { failure = .oversized; break }
        }

        // The child is reaped only after the group is gone, so its pid cannot be reused meanwhile.
        terminateGroup(pid, graceful: failure != nil && !hasExited(pid))
        // Retire the group before reaping can make its PID available to another process.
        lock.lock()
        group = 0
        lock.unlock()
        let status = reap(pid)
        if let failure { return failure }
        if isCancelled { return .cancelled }
        let signal = status & 0x7f
        return signal == 0 ? .exited((status >> 8) & 0xff, stdout: stdout, stderrBytes: stderrBytes)
            : .signaled(signal)
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Checks for exit without reaping.
    private func hasExited(_ pid: pid_t) -> Bool {
        var info = siginfo_t()
        return waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == pid
    }

    private func terminateGroup(_ pid: pid_t, graceful: Bool) {
        guard kill(-pid, 0) == 0 else { return }
        if graceful {
            kill(-pid, SIGTERM)
            let until = MonotonicClock.now() + seconds(limits.killGrace)
            while MonotonicClock.now() < until, !hasExited(pid) { usleep(20_000) }
        }
        kill(-pid, SIGKILL)
    }

    private func reap(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        return status
    }
}
