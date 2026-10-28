import Darwin
import Foundation
import OverlayCore

func checkServerLifetime() {
    for signal in [SIGTERM, SIGKILL] {
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/bin/sleep")
        server.arguments = ["30"]
        do { try server.run() } catch {
            check(false, "starts fake server: \(error)")
            continue
        }
        let ended = DispatchSemaphore(value: 0)
        let watch = ServerLifetime.watch(pid: server.processIdentifier,
                                         queue: DispatchQueue(label: "test.server-exit")) { ended.signal() }
        check(ended.wait(timeout: .now() + 0.05) == .timedOut, "live server does not stop overlay")
        kill(server.processIdentifier, signal)
        server.waitUntilExit()
        check(ended.wait(timeout: .now() + 2) == .success, "server signal \(signal) stops overlay")
        watch.cancel()

        let alreadyEnded = DispatchSemaphore(value: 0)
        let lateWatch = ServerLifetime.watch(pid: server.processIdentifier,
                                             queue: DispatchQueue(label: "test.server-already-exited")) {
            alreadyEnded.signal()
        }
        check(alreadyEnded.wait(timeout: .now() + 2) == .success, "server exit before registration stops overlay")
        lateWatch.cancel()
    }
}
