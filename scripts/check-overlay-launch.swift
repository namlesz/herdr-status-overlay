import Darwin
import Foundation

// Test the real launch scripts with a fake helper, without Herdr or GUI.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let manager = FileManager.default
try manager.createDirectory(at: temporary.appendingPathComponent("bin"), withIntermediateDirectories: true)
try manager.createDirectory(at: temporary.appendingPathComponent(".build/release"), withIntermediateDirectories: true)
defer { try? manager.removeItem(at: temporary) }
try manager.copyItem(at: root.appendingPathComponent("bin/run-helper"),
                     to: temporary.appendingPathComponent("bin/run-helper"))
let helper = temporary.appendingPathComponent(".build/release/HerdrStatusOverlay")
try """
#!/bin/sh
printf '%s\\n' "$HERDR_OVERLAY_SERVER_PID" > "$HERDR_PLUGIN_STATE_DIR/started"
sleep 1
printf 'finished\\n'
""".write(to: helper, atomically: true, encoding: .utf8)
try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)

for event in ["startup", "action"] {
    let state = temporary.appendingPathComponent(event)
    let process = Process()
    process.executableURL = root.appendingPathComponent("bin/open-overlay")
    var environment = ProcessInfo.processInfo.environment
    environment["HERDR_PLUGIN_ROOT"] = temporary.path
    environment["HERDR_PLUGIN_STATE_DIR"] = state.path
    environment["HERDR_PLUGIN_EVENT"] = event
    // No Herdr command is needed or allowed by this fixture.
    environment["HERDR_BIN_PATH"] = "/does-not-exist"
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    let start = Date()
    try process.run()
    process.waitUntilExit()
    let captured = output.fileHandleForReading.readDataToEndOfFile()
    precondition(process.terminationStatus == 0, "launcher failed")
    precondition(captured.isEmpty && Date().timeIntervalSince(start) < 0.8,
                 "launcher must return immediately and release Herdr's output pipes")
    let deadline = Date().addingTimeInterval(3)
    let log = state.appendingPathComponent("helper.log")
    while Date() < deadline {
        if (try? String(contentsOf: log, encoding: .utf8))?.contains("finished") == true { break }
        Thread.sleep(forTimeInterval: 0.01)
    }
    let parent = try String(contentsOf: state.appendingPathComponent("started"), encoding: .utf8)
    let messages = try String(contentsOf: log, encoding: .utf8)
    precondition(parent.trimmingCharacters(in: .whitespacesAndNewlines) == String(getpid()),
                 "captures server parent PID")
    precondition(messages.contains("finished"), "helper finishes in background")
    let permissions = try manager.attributesOfItem(atPath: log.path)[.posixPermissions] as! Int
    precondition(permissions & 0o077 == 0, "helper log is private")
}

try manager.removeItem(at: helper)
let missing = Process()
missing.executableURL = root.appendingPathComponent("bin/open-overlay")
missing.environment = ["HERDR_PLUGIN_ROOT": temporary.path, "HERDR_PLUGIN_STATE_DIR": temporary.path]
missing.standardError = FileHandle.nullDevice
try missing.run()
missing.waitUntilExit()
precondition(missing.terminationStatus == 1, "missing build is reported by the action")
print("Background launch checks passed (startup, action, parent PID, stdio, log permissions, missing build).")
