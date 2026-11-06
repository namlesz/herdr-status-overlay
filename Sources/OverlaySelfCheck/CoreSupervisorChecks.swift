import Darwin
import Foundation
import OverlayCore

func checkCoreSupervisor() {
    let lock = NSLock()
    var core: pid_t? = 1001
    var children: [Process] = []
    let supervisor = CoreSupervisor(pollInterval: 0.02)
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        supervisor.run(corePID: { lock.lock(); defer { lock.unlock() }; return core }, launch: { _ in
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sleep"); process.arguments = ["30"]
            lock.lock(); children.append(process); lock.unlock(); return process
        })
        finished.signal()
    }
    func waitForChildren(_ count: Int) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            lock.lock(); let reached = children.count >= count; lock.unlock()
            if reached { return true }; usleep(10_000)
        }
        return false
    }
    guard waitForChildren(1) else { check(false, "supervisor launches once for an observed core"); supervisor.stop(); _ = finished.wait(timeout: .now() + 2); return }
    check(true, "supervisor launches once for an observed core")
    lock.lock(); let first = children.first!; lock.unlock()
    let launchDeadline = Date().addingTimeInterval(2)
    while !first.isRunning && Date() < launchDeadline { usleep(10_000) }
    check(first.isRunning, "helper process started")
    first.terminate()
    usleep(80_000)
    lock.lock(); let once = children.count == 1; core = 1002; lock.unlock()
    check(once, "manual child quit does not restart for the same core PID")
    check(waitForChildren(2), "new core PID allows one new helper")
    supervisor.stop()
    check(finished.wait(timeout: .now() + 2) == .success, "supervisor stop waits for its owned child cleanup")
    lock.lock(); let stopped = children.allSatisfy { !$0.isRunning }; lock.unlock()
    check(stopped, "supervisor termination leaves no helper child")

    let ready = FileManager.default.temporaryDirectory.appendingPathComponent("overlay-child-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: ready) }
    let retrying = CoreSupervisor(pollInterval: 0.02)
    let retried = DispatchSemaphore(value: 0)
    var attempts = 0
    var stubborn: Process?
    DispatchQueue.global().async {
        retrying.run(corePID: { 1003 }, launch: { _ in
            attempts += 1
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            if attempts == 1 {
                process.arguments = ["-c", "exit 2"]
            } else {
                process.arguments = ["-c", "trap '' TERM; echo ready > \"$1\"; while :; do sleep 0.1; done", "fake-helper", ready.path]
                stubborn = process
            }
            return process
        })
        retried.signal()
    }
    let readinessDeadline = Date().addingTimeInterval(3)
    while !FileManager.default.fileExists(atPath: ready.path) && Date() < readinessDeadline { usleep(10_000) }
    check(FileManager.default.fileExists(atPath: ready.path), "startup failure retries for the same core PID")
    let stoppingAt = Date()
    retrying.stop()
    let reaped = retried.wait(timeout: .now() + 2) == .success
    if !reaped, let process = stubborn, process.isRunning { kill(process.processIdentifier, SIGKILL) }
    check(reaped && Date().timeIntervalSince(stoppingAt) < 2, "supervisor escalates an unresponsive helper within its stop deadline")
    check(reaped && stubborn?.isRunning == false && stubborn?.terminationStatus == SIGKILL,
          "supervisor reaps only its owned TERM-ignoring helper")
}
