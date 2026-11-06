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
