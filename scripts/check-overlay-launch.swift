import Darwin
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let manager = FileManager.default
let binary = temporary.appendingPathComponent(".build/release/HerdrStatusOverlay")
try manager.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
try manager.createDirectory(at: temporary.appendingPathComponent("bin"), withIntermediateDirectories: true)
try manager.copyItem(at: root.appendingPathComponent("bin/open-overlay"), to: temporary.appendingPathComponent("bin/open-overlay"))
defer { try? manager.removeItem(at: temporary) }
try "#!/bin/sh\nprintf 'started\\n'\nsleep 1\nprintf 'finished\\n'\n".write(to: binary, atomically: true, encoding: .utf8)
try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
let state = temporary.appendingPathComponent("state")
let process = Process()
process.executableURL = temporary.appendingPathComponent("bin/open-overlay")
process.environment = ["HOME": temporary.path, "HERDR_OVERLAY_STATE_DIR": state.path, "PATH": "/usr/bin:/bin"]
let output = Pipe(); process.standardOutput = output; process.standardError = output
let start = Date()
try process.run(); process.waitUntilExit()
let result = output.fileHandleForReading.readDataToEndOfFile()
precondition(process.terminationStatus == 0 && result.isEmpty && Date().timeIntervalSince(start) < 0.8,
             "manual launcher returns without waiting for helper")
let log = state.appendingPathComponent("overlay.log")
let deadline = Date().addingTimeInterval(3)
while Date() < deadline {
    if (try? String(contentsOf: log, encoding: .utf8))?.contains("finished") == true { break }
    Thread.sleep(forTimeInterval: 0.02)
}
let contents = try String(contentsOf: log, encoding: .utf8)
precondition(contents.contains("started") && contents.contains("finished"), "helper output is captured in state log")
let permissions = try manager.attributesOfItem(atPath: log.path)[.posixPermissions] as! Int
precondition(permissions & 0o077 == 0, "state log is private")
print("Manual launch script checks passed (background, immediate return, private log).")

// Compile the real startup guard without connecting to core or initializing AppKit.
let appSource = try String(contentsOf: root.appendingPathComponent("Sources/OverlayApp/main.swift"), encoding: .utf8)
let detachGuards = appSource.split(separator: "\n").filter { $0.contains("Unable to detach overlay session.") }
precondition(detachGuards.count == 1, "locates the production session-detachment guard")
let fixtureSource = temporary.appendingPathComponent("session-check.swift")
let fixtureBinary = temporary.appendingPathComponent("session-check")
try """
import Darwin
func die(_ message: String) -> Never {
    fputs(message + "\\n", stderr); exit(2)
}
let joinsParentGroup = CommandLine.arguments.count > 1
if joinsParentGroup {
    guard let parentGroup = pid_t(CommandLine.arguments[1]), setpgid(0, parentGroup) == 0 else {
        die("Unable to join the test parent's process group.")
    }
    precondition(getpgrp() != getpid(), "manual launch starts as a process-group member")
} else {
    precondition(getpgrp() == getpid(), "Foundation Process creates a process-group leader")
    precondition(setsid() == -1 && errno == EPERM, "reproduces the supervisor startup failure")
}
let originalSession = getsid(0)
\(detachGuards[0])
precondition(getpgrp() == getpid(), "overlay has its own process group")
precondition(getsid(0) == (joinsParentGroup ? getpid() : originalSession),
             "manual launch detaches its session; supervisor launch preserves its session")
""".write(to: fixtureSource, atomically: true, encoding: .utf8)
let compiler = Process()
compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
compiler.arguments = ["swiftc", fixtureSource.path, "-o", fixtureBinary.path]
try compiler.run(); compiler.waitUntilExit()
precondition(compiler.terminationStatus == 0, "session-detachment fixture compiles")
for arguments in [[], [String(getpgrp())]] {
    let child = Process()
    child.executableURL = fixtureBinary; child.arguments = arguments
    try child.run(); child.waitUntilExit()
    precondition(child.terminationReason == .exit && child.terminationStatus == 0,
                 "session detachment succeeds for supervisor and manual launch")
}
print("Session-detachment checks passed (Foundation Process leader and inherited process group).")
