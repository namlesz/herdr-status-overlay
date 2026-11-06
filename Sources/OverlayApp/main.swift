import AppKit
import Darwin
import OverlayCore

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8)); exit(2)
}
if CommandLine.arguments.contains("--watch-core") {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let supervisor = CoreSupervisor()
    var signals: [DispatchSourceSignal] = []
    for number in [SIGTERM, SIGINT, SIGHUP] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { supervisor.stop() }; source.resume(); signals.append(source)
    }
    supervisor.run(corePID: { CoreRPCClient()?.pid }, launch: { expectedPID in
        let process = Process(); process.executableURL = executable; process.arguments = ["--foreground"]
        var childEnvironment = ProcessInfo.processInfo.environment
        childEnvironment["HERDR_OVERLAY_EXPECTED_CORE_PID"] = String(expectedPID)
        process.environment = childEnvironment
        return process
    })
    exit(0)
}

let environment = ProcessInfo.processInfo.environment
guard let core = CoreRPCClient(environment: environment) else { die("Herdr core is not available on its existing local socket.") }
if let expected = environment["HERDR_OVERLAY_EXPECTED_CORE_PID"], Int32(expected) != core.pid {
    die("The observed Herdr core changed before overlay startup.")
}
core.reconnect() // Only the PID check used this socket; event sources open their own pinned connections.
let home = environment["HOME"] ?? NSHomeDirectory()
let stateURL: URL
do {
    stateURL = try OverlayStateDirectory.resolve(home: home, xdgStateHome: environment["XDG_STATE_HOME"],
                                                 override: environment["HERDR_OVERLAY_STATE_DIR"])
} catch {
    die("Unable to copy overlay settings; original settings were left untouched: \(error)")
}

try? FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let lockPath = stateURL.appendingPathComponent("overlay.lock").path
let lockFD = open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
var lockInfo = stat()
guard lockFD >= 0, fstat(lockFD, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG,
      lockInfo.st_uid == getuid(), flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { exit(0) }
guard setsid() >= 0 else { die("Unable to detach overlay session.") }
var stopOverlay: () -> Void = { exit(0) }
let serverWatch = ServerLifetime.watch(pid: core.pid) { stopOverlay() }
let source = SourceConfig.local(executable: "core-rpc")
let readCore: ([String]) -> RunOutcome = { _ in
    do { return .exited(0, stdout: try core.snapshot(), stderrBytes: 0) }
    catch { return .timedOut }
}

signal(SIGPIPE, SIG_IGN)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
typealias CGSDefaultConnection = @convention(c) () -> Int32
typealias CGSSetConnectionProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
if let image = dlopen(nil, RTLD_NOW), let defaultConnection = dlsym(image, "_CGSDefaultConnection"),
   let setProperty = dlsym(image, "CGSSetConnectionProperty") {
    let connection = unsafeBitCast(defaultConnection, to: CGSDefaultConnection.self)()
    _ = unsafeBitCast(setProperty, to: CGSSetConnectionProperty.self)(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
}
let controller = AppController(sources: [source], stateDirectory: stateURL, read: readCore, cancelRead: { core.cancel() },
                               makeEventSource: { model in CoreEventSource(environment: environment, expectedPID: core.pid, model: model) })
app.delegate = controller
stopOverlay = { controller.shutdown() }
var signalSources: [DispatchSourceSignal] = []
for number in [SIGHUP, SIGTERM, SIGINT] {
    signal(number, SIG_IGN)
    let signalSource = DispatchSource.makeSignalSource(signal: number, queue: .main)
    signalSource.setEventHandler { controller.shutdown() }; signalSource.resume(); signalSources.append(signalSource)
}
_ = serverWatch

print("Herdr Status Overlay connected read-only to core PID \(core.pid).")
app.run()
