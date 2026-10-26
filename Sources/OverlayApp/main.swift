import AppKit
import Darwin
import OverlayCore

// Started by the plugin pane (bin/run-helper). Stays in the foreground of that pane:
// closing the pane (SIGHUP), SIGTERM/SIGINT or Quit stops the reads and exits. Agents are untouched.

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
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        print("Status overlay już działa w innym panelu.")
        exit(0)
    }
    return fd
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
let controller = AppController(sources: sources, stateDirectory: stateURL)
app.delegate = controller

var signalSources: [DispatchSourceSignal] = []
for number in [SIGHUP, SIGTERM, SIGINT] {
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler { controller.shutdown() }
    source.resume()
    signalSources.append(source)
}

print("Status overlay działa: lokalna sesja + \(machines.aliases.count) zapisanych maszyn.")
print("Close this pane or choose “Quit overlay” in the HSO menu to stop it.")
app.run()
