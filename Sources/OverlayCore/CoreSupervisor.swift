import Darwin
import Foundation

/// Watches observed core PIDs and owns only the overlay child it launches.
public final class CoreSupervisor {
    private let lock = NSLock()
    private var stopping = false
    private var child: Process?
    private let pollInterval: TimeInterval

    public init(pollInterval: TimeInterval = 2) { self.pollInterval = pollInterval }

    public func stop() {
        lock.lock(); stopping = true; let process = child; lock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }

    public func run(corePID: () -> pid_t?, launch: (pid_t) -> Process?) {
        var lastPID: pid_t = 0
        while !isStopping {
            guard let pid = corePID(), pid > 1 else { Thread.sleep(forTimeInterval: pollInterval); continue }
            guard pid != lastPID else { Thread.sleep(forTimeInterval: pollInterval); continue }
            guard let process = launch(pid) else { Thread.sleep(forTimeInterval: pollInterval); continue }
            lock.lock(); child = process; let shouldStop = stopping; lock.unlock()
            do { try process.run() } catch {
                clear(process)
                Thread.sleep(forTimeInterval: pollInterval)
                continue
            }
            if shouldStop { process.terminate() }
            while process.isRunning && !isStopping { usleep(50_000) }
            if process.isRunning {
                process.terminate()
                let deadline = MonotonicClock.now() + seconds(1)
                while process.isRunning && MonotonicClock.now() < deadline { usleep(10_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            clear(process)
            // Exit 2 means startup failed before the UI was ready; a clean Quit must not relaunch.
            if process.terminationReason == .exit && process.terminationStatus == 2 {
                Thread.sleep(forTimeInterval: pollInterval)
            } else {
                lastPID = pid
            }
        }
    }

    private var isStopping: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopping
    }

    private func clear(_ process: Process) {
        lock.lock(); if child === process { child = nil }; lock.unlock()
    }
}
