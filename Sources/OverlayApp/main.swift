import AppKit
import Darwin
import OverlayCore

// Started without a terminal by bin/open-overlay; server exit or Quit stops reads, not agents.

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

let environment = ProcessInfo.processInfo.environment
guard let herdr = environment["HERDR_BIN_PATH"], herdr.hasPrefix("/") else {
    die("Brak HERDR_BIN_PATH: uruchom overlay akcją pluginu Herdr.")
}
guard environment["HERDR_SOCKET_PATH"] != nil,
      let stateDir = environment["HERDR_PLUGIN_STATE_DIR"],
      let configDir = environment["HERDR_PLUGIN_CONFIG_DIR"] else {
    die("Brak kontekstu pluginu (HERDR_SOCKET_PATH, HERDR_PLUGIN_STATE_DIR, HERDR_PLUGIN_CONFIG_DIR).")
}
guard let rawPID = environment["HERDR_OVERLAY_SERVER_PID"], let serverPID = pid_t(rawPID), serverPID > 1 else {
    die("Brak PID serwera: uruchom overlay akcją pluginu Herdr.")
}
guard setsid() >= 0 else { die("Nie można odłączyć overlayu od terminala.") }
var stopOverlay: () -> Void = { exit(0) }
// Register before the handoff lock wait, so a later PID reuse cannot hide server exit.
let serverWatch = ServerLifetime.watch(pid: serverPID) { stopOverlay() }
let stateURL = URL(fileURLWithPath: stateDir, isDirectory: true)

/// Held for the whole process lifetime; a second helper exits without touching the first.
func acquireInstanceLock() -> Int32 {
    do {
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    } catch {
        die("Nie można utworzyć katalogu stanu pluginu.")
    }
    let path = stateURL.appendingPathComponent("helper.lock").path
    let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    var info = stat()
    guard fd >= 0, fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
        die("Niepoprawny plik blokady helper.lock.")
    }
    // During handoff the old helper needs a moment to drain reads and release its lock.
    let attempts = environment["HERDR_PLUGIN_EVENT"] == "startup" ? 100 : 1
    for attempt in 0..<attempts {
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
        guard errno == EWOULDBLOCK else { die("Nie można zablokować helper.lock.") }
        if attempt + 1 < attempts { Thread.sleep(forTimeInterval: 0.1) }
    }
    print("Status overlay już działa.")
    exit(0)
}

let instanceLock = acquireInstanceLock()

var machines = MachineList.Parsed()
do {
    machines = try MachineList.load(directory: URL(fileURLWithPath: configDir, isDirectory: true))
} catch {
    print("Nie można odczytać \(MachineList.fileName); tylko lokalna sesja.")
}
if !machines.rejectedLines.isEmpty {
    print("Pominięto niepoprawne wiersze \(MachineList.fileName): \(machines.rejectedLines.map(String.init).joined(separator: ", ")).")
}

let sources = [SourceConfig.local(executable: herdr)]
    + machines.aliases.map { SourceConfig.machine($0, executable: herdr) }

signal(SIGPIPE, SIG_IGN)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// The app is never active and WindowServer drops cursor changes from background apps;
// this private connection property lets the hand cursor over clickable rows through.
typealias CGSDefaultConnection = @convention(c) () -> Int32
typealias CGSSetConnectionProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
if let image = dlopen(nil, RTLD_NOW),
   let defaultConnection = dlsym(image, "_CGSDefaultConnection"),
   let setProperty = dlsym(image, "CGSSetConnectionProperty") {
    let connection = unsafeBitCast(defaultConnection, to: CGSDefaultConnection.self)()
    _ = unsafeBitCast(setProperty, to: CGSSetConnectionProperty.self)(
        connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
} else {
    print("Brak CGSSetConnectionProperty; kursor nie zmieni się nad klikalnymi elementami.")
}
let controller = AppController(sources: sources, stateDirectory: stateURL)
app.delegate = controller
stopOverlay = { controller.shutdown() }

var signalSources: [DispatchSourceSignal] = []
for number in [SIGHUP, SIGTERM, SIGINT] {
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler { controller.shutdown() }
    source.resume()
    signalSources.append(source)
}

print("Status overlay działa: lokalna sesja + \(machines.aliases.count) zapisanych maszyn.")
print("Choose “Quit overlay” in the HSO menu to stop it.")
app.run()
