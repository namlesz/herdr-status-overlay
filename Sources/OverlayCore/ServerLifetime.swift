import Darwin
import Foundation

/// Watches the exact server process, not socket availability or the presence of a client.
public enum ServerLifetime {
    public static func watch(pid: pid_t, queue: DispatchQueue = .main,
                             onExit: @escaping () -> Void) -> DispatchSourceProcess {
        precondition(pid > 1)
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler(handler: onExit)
        // The server may have exited before the kernel registered the watch.
        source.setRegistrationHandler {
            if kill(pid, 0) != 0 && errno == ESRCH { onExit() }
        }
        source.resume()
        return source
    }
}
