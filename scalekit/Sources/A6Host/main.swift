import Foundation
import ScaleKit

// a6host — Phase 1 macOS harness (experiments E1/E2) for the realme Smart Scale.
//
//   a6host scan    [--duration N]                 discover + persist scale identity
//   a6host pair    [--slot N] [--unbind] [--mac MAC] [--notes S]
//                                                 E1: full pair/bind handshake
//   a6host session [--slot N] [--unit kg] [--arm] [--mac MAC] [--notes S] [--timeout S]
//                                                 E2: init/config/live/history flow
//   a6host status                                  show persisted scan/bind state
//
// Every run writes a replay-harness capture (analysis/captures/README.md schema)
// — on success, abort, Ctrl-C, or timeout.

// MARK: - Arg parsing

struct Args {
    var command: String = ""
    var duration: TimeInterval = 60
    var slot: Int = 1
    var unbind = false
    var mac: String?
    var unit = UnitType.kg
    var arm = false
    var notes = ""
    var timeout: TimeInterval = 180
    var outDir: String?
    var skipRegister = false
    var deviceId: String?
    var fast = false

    static func parse(_ a: [String]) -> Args {
        var v = Args()
        var i = 0
        func next(_ name: String) -> String {
            i += 1
            guard i < a.count else {
                print("missing value for \(name)"); exit(2)
            }
            return a[i]
        }
        while i < a.count {
            switch a[i] {
            case "scan", "pair", "session", "status", "replay": v.command = a[i]
            case "--duration": v.duration = Double(next("--duration")) ?? 60
            case "--slot": v.slot = Int(next("--slot")) ?? 1
            case "--unbind": v.unbind = true
            case "--mac": v.mac = next("--mac")
            case "--unit": v.unit = UnitType(rawValue: UInt8(next("--unit")) ?? 0) ?? .kg
            case "--arm": v.arm = true
            case "--notes": v.notes = next("--notes")
            case "--timeout": v.timeout = Double(next("--timeout")) ?? 180
            case "--skip-register": v.skipRegister = true
            case "--out": v.outDir = next("--out")
            case "--dev": v.deviceId = next("--dev")
            case "--fast": v.fast = true
            default: break
            }
            i += 1
        }
        return v
    }
}

// MARK: - Capture output location (repo analysis/captures when available)

func captureDirectory(_ override: String?) -> URL {
    if let o = override { return URL(fileURLWithPath: o, isDirectory: true) }
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    for candidate in [cwd, cwd.deletingLastPathComponent(), cwd.deletingLastPathComponent().deletingLastPathComponent()] {
        let dir = candidate.appendingPathComponent("analysis/captures", isDirectory: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue {
            return dir
        }
    }
    let fallback = cwd.appendingPathComponent("captures", isDirectory: true)
    try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
    return fallback
}

func timestamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    f.timeZone = TimeZone.current
    return f.string(from: Date())
}

// MARK: - App wiring

let args = Args.parse(CommandLine.arguments)
let console = Console()

if args.command == "status" {
    if let s = ScanStore.last() {
        print("scanstore: id \(s.identifier) mac \(s.mac) name \(s.name ?? "-")")
    } else {
        print("scanstore: empty (run `a6host scan` first)")
    }
    if let b = try? Data(contentsOf: BindStore.fileURL),
       let r = try? JSONDecoder().decode(BindStore.Record.self, from: b) {
        print("bind:     deviceId \(r.deviceId) mac \(r.mac) slot \(r.slot) fw \(r.firmwareVersion) at \(r.boundAt)")
    } else {
        print("bind:     empty (run `a6host pair` first)")
    }
    exit(0)
}

guard !args.command.isEmpty else {
    print("""
    usage:
      a6host scan    [--duration N]
      a6host pair    [--slot N] [--unbind] [--skip-register] [--mac MAC] [--dev DEVICEID] [--notes S]
      a6host session [--slot N] [--unit kg] [--arm] [--mac MAC] [--notes S] [--timeout S]
      a6host replay  <capture.json> [--slot N] [--mac MAC]
      a6host status
    """)
    exit(2)
}

if args.command == "replay" {
    guard let p = CommandLine.arguments.firstIndex(of: "replay").map({ CommandLine.arguments[$0 + 1] }) else {
        print("usage: a6host replay <capture.json>")
        exit(2)
    }
    exit(ReplayCommand.run(path: p, slot: args.slot, macOverride: args.mac))
}

let host = BleHost(mac: args.mac ?? "", runMode: args.command == "scan" ? .scan(args.duration) : .run,
                   out: console)
var runKind = args.command            // "pair" | "session"
if args.command == "scan" { runKind = "scan" }

var terminalReason = "run ended"
var exitCode = 0

/// Save the capture + print the experiment summary; single exit path.
func finish(reason: String, code: Int32) -> Never {
    if let d = host.driver {
        // Bind persistence (E1 success → E2 deviceId).
        if let p = d as? PairDriver, let rec = p.bindRecord {
            BindStore.save(rec)
        }
        do {
            let dir = captureDirectory(args.outDir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(d.recorder.kind)_\(timestamp()).json")
            try d.recorder.json().write(to: url, options: .atomic)
            print("\n=== \(reason) ===")
            print(d.summary)
            print("capture: \(url.path) (\(d.recorder.eventCount) events)")
        } catch {
            print("!! capture save failed: \(error)")
            exitCode = 3
        }
    } else {
        print("\n=== \(reason) === (no driver — nothing captured)")
    }
    exit(Int32(code == 0 ? Int32(exitCode) : code))
}

// Driver creation is deferred until the scale's MAC is known (discovery or scanstore).
host.driverFactory = { mac in
    switch args.command {
    case "pair":
        return PairDriver(host: host, slot: args.slot,
                          mode: args.unbind ? .unbind : .bind,
                          skipRegister: args.skipRegister, notes: args.notes,
                          deviceIdOverride: args.deviceId, fast: args.fast)
    case "session":
        return SessionDriver(host: host, slot: args.slot, unit: args.unit,
                             armMeasurement: args.arm, notes: args.notes)
    default:
        return nil
    }
}

host.onDone = { reason in
    finish(reason: reason, code: 0)
}

// Status ticker.
let ticker = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
    if let d = host.driver { console.printLine("… \(d.statusLine)") }
}

// Run timeout: pair window is 180 s officially; sessions get --timeout.
if args.command != "scan" {
    DispatchQueue.main.asyncAfter(deadline: .now() + args.timeout) { [weak host] in
        guard let host else { return }
        if let d = host.driver, d.isFinished { return }
        finish(reason: "timeout after \(Int(args.timeout))s", code: 1)
    }
}

// Ctrl-C: save the capture before exiting (signal-safe via DispatchSource on main).
signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler {
    ticker.invalidate()
    finish(reason: "interrupted (SIGINT)", code: 130)
}
sigint.resume()

print("a6host — \(args.command) (slot \(args.slot), notes \"\(args.notes)\")")
host.start()
RunLoop.main.run()
