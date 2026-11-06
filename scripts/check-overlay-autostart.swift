import Foundation

let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let base = FileManager.default.temporaryDirectory.appendingPathComponent("overlay autostart \(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: base) }
let repo = base.appendingPathComponent("repo with spaces")
let home = base.appendingPathComponent("home with spaces")
let xdg = home.appendingPathComponent("xdg state")
let fakeBin = base.appendingPathComponent("fake-bin")
let helper = repo.appendingPathComponent(".build/release/HerdrStatusOverlay")
try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: repo.appendingPathComponent("bin"), withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: home.appendingPathComponent(".local/state/herdr/plugins/local.status-overlay"), withIntermediateDirectories: true)
let legacyPanel = home.appendingPathComponent(".local/state/herdr/plugins/local.status-overlay/panel.json")
try Data("keep-settings".utf8).write(to: legacyPanel)
for name in ["install-autostart", "uninstall-autostart"] {
    try FileManager.default.copyItem(at: source.appendingPathComponent("bin/\(name)"), to: repo.appendingPathComponent("bin/\(name)"))
}
try "#!/bin/sh\nexit 0\n".write(to: helper, atomically: true, encoding: .utf8)
let log = base.appendingPathComponent("launchctl.log")
let fakeLaunchctl = fakeBin.appendingPathComponent("launchctl")
try "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$FAKE_LAUNCHCTL_LOG\"\n".write(to: fakeLaunchctl, atomically: true, encoding: .utf8)
for path in [helper.path, fakeLaunchctl.path] { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path) }
func run(_ name: String) -> Int32 {
    let process = Process(); process.executableURL = repo.appendingPathComponent("bin/\(name)")
    process.environment = ["HOME": home.path, "PATH": fakeBin.path + ":/usr/bin:/bin", "XDG_STATE_HOME": xdg.path,
                           "HC_SESSION": "session one", "HERDR_OVERLAY_SOCKET_PATH": "/tmp/fake socket.sock",
                           "HERDR_APP_HOME": "/tmp/app home", "HERDR_APP_BIN_PATH": "/tmp/herdr-app",
                           "FAKE_LAUNCHCTL_LOG": log.path]
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    do { try process.run(); process.waitUntilExit(); return process.terminationStatus } catch { return -1 }
}
precondition(run("install-autostart") == 0, "installs only a scratch LaunchAgent")
let plist = home.appendingPathComponent("Library/LaunchAgents/dev.herdr.status-overlay.plist")
let original = try Data(contentsOf: plist)
let job = try PropertyListSerialization.propertyList(from: original, options: [], format: nil) as! [String: Any]
let args = job["ProgramArguments"] as! [String]
let env = job["EnvironmentVariables"] as! [String: String]
precondition(job["Label"] as? String == "dev.herdr.status-overlay" && args == [helper.path, "--watch-core"], "plist safely records exact helper and supervisor mode")
precondition(job["StandardOutPath"] as? String == xdg.appendingPathComponent("herdr-status-overlay/supervisor.log").path, "uses XDG state path")
for key in ["HOME", "PATH", "XDG_STATE_HOME", "HC_SESSION", "HERDR_OVERLAY_SOCKET_PATH", "HERDR_APP_HOME", "HERDR_APP_BIN_PATH"] {
    precondition(env[key] != nil, "preserves launch environment \(key)")
}
precondition(env["HC_SESSION"] == "session one" && env["HERDR_OVERLAY_SOCKET_PATH"] == "/tmp/fake socket.sock", "preserves values containing spaces")
precondition(run("install-autostart") != 0, "refuses to overwrite an existing LaunchAgent")
let unrelated: [String: Any] = ["Label": "dev.herdr.status-overlay", "ProgramArguments": ["/other/overlay", "--watch-core"], "WorkingDirectory": "/other"]
let unrelatedData = try PropertyListSerialization.data(fromPropertyList: unrelated, format: .xml, options: 0)
try unrelatedData.write(to: plist)
precondition(run("uninstall-autostart") != 0 && FileManager.default.fileExists(atPath: plist.path), "refuses to uninstall an unrelated job")
try original.write(to: plist)
precondition(run("uninstall-autostart") == 0 && !FileManager.default.fileExists(atPath: plist.path), "uninstalls only its own scratch LaunchAgent")
let danglingTarget = base.appendingPathComponent("must-not-be-created.plist")
try FileManager.default.createSymbolicLink(at: plist, withDestinationURL: danglingTarget)
precondition(run("install-autostart") != 0 && !FileManager.default.fileExists(atPath: danglingTarget.path),
             "refuses a dangling plist symlink without following its target")
try FileManager.default.removeItem(at: plist)
let preservedLegacy = try Data(contentsOf: legacyPanel)
precondition(preservedLegacy == Data("keep-settings".utf8), "legacy settings are never modified")
let calls = try String(contentsOf: log, encoding: .utf8)
precondition(calls.contains("bootstrap gui/") && calls.contains("bootout gui/"), "uses user-scoped launchctl only")
print("Scratch LaunchAgent checks passed (spaces, environment, bootstrap, overwrite refusal, safe uninstall).")
