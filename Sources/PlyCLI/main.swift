import Foundation
import PlyCore
import PlyShared

let usage = """
ply \(PlyInfo.version): keep your Mac on iPhone USB, combine Wi-Fi + iPhone.

Usage:
  ply status [--json|--md]          Which link is in use, live speeds, findings
  ply diagnose [--json]             What is wrong and how to fix it
  ply prefer-usb                    Put iPhone USB above Wi-Fi (needs helper)
  ply combine on [--split connection|site] [--no-system-proxy]
  ply combine off
  ply speedtest [--seconds N] [--mode each|combined|both] [--json]
  ply wifi on|off|disconnect
  ply settings                      Show settings
  ply settings set key=value ...    Change settings (see `ply docs llms-full`)
  ply repair                        Restart the iPhone USB service (needs helper)
  ply restore-proxies               Undo any proxy change Ply made
  ply helper install|uninstall|status
  ply login-item on|off             Open Ply.app at login
  ply agent-prompt                  Print a prompt for an AI agent
  ply actions [--json]              List every action
  ply action <id> ['{"json":"params"}']   Run any action by id
  ply mcp                           Run the MCP server on stdio
  ply daemon                        Run the engine without the menu bar app
  ply docs llms|llms-full|skill     Print agent docs; `ply docs write <repo>` writes them
  ply open                          Show Ply's window (when the menu bar icon is hidden)
  ply about | quit | version

Every command prints JSON with --json (most print JSON anyway). Exit code 0 = ok, 1 = error, 2 = usage.
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func block<T>(_ body: @escaping () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    var result: Result<T, Error>!
    Task {
        do { result = .success(try await body()) } catch { result = .failure(error) }
        sem.signal()
    }
    sem.wait()
    return try result.get()
}

var args = Array(CommandLine.arguments.dropFirst())
let json = args.contains("--json")
let md = args.contains("--md")
args.removeAll { $0 == "--json" || $0 == "--md" }

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func run(_ id: ActionID, _ params: Params = [:], printer: ((JSONValue) -> String)? = nil) -> Never {
    do {
        let value = try block { try await Runner.run(id, params) }
        if let printer, !json { print(printer(value)) } else { print(value.pretty()) }
        exit(0)
    } catch {
        let e = PlyError.wrap(error)
        if json { print(e.json.pretty()) } else {
            var msg = "error: \(e.message)"
            if let fix = e.fix { msg += "\nfix: \(Registry.spec(fix).cli)" }
            FileHandle.standardError.write(Data((msg + "\n").utf8))
        }
        exit(1)
    }
}

var signalSources: [DispatchSourceSignal] = []

func parseValue(_ raw: String) -> JSONValue {
    if raw == "true" { return .bool(true) }
    if raw == "false" { return .bool(false) }
    if let n = Double(raw), !raw.isEmpty { return .number(n) }
    if raw.hasPrefix("[") || raw.hasPrefix("{"), let v = try? JSONValue.parse(Data(raw.utf8)) { return v }
    return .string(raw)
}

func statusText(_ v: JSONValue) -> String {
    guard let r = try? v.decode(as: StatusReport.self) else { return v.pretty() }
    return md ? StatusMarkdown.render(r) : StatusMarkdown.plain(r)
}

guard let command = args.first else { print(usage); exit(0) }
let rest = Array(args.dropFirst())

switch command {
case "status":
    run(.status, printer: statusText)
case "diagnose":
    run(.diagnose) { v in
        let findings = (try? v["findings"]?.decode(as: [Finding].self)) ?? []
        return ([v["summary"]?.stringValue ?? ""] + findings.map { f in
            "[\(f.severity.rawValue)] \(f.title)\n    \(f.detail)" + (f.fix.map { "\n    fix: \(Registry.spec($0).cli)" } ?? "")
        }).joined(separator: "\n")
    }
case "prefer-usb":
    run(.preferUSB)
case "combine":
    switch rest.first {
    case "on", "start":
        var p: Params = [:]
        if let s = option("--split") { p["split"] = .string(s) }
        if rest.contains("--no-system-proxy") { p["systemProxy"] = .bool(false) }
        run(.combineStart, p)
    case "off", "stop":
        run(.combineStop)
    default:
        fail("usage: ply combine on|off", code: 2)
    }
case "speedtest", "speed-test":
    var p: Params = [:]
    if let s = option("--seconds"), let n = Int(s) { p["seconds"] = .number(Double(n)) }
    if let m = option("--mode") { p["mode"] = .string(m) }
    FileHandle.standardError.write(Data("Running speed test (uses mobile data on the iPhone link)...\n".utf8))
    run(.speedTest, p) { v in
        guard let r = try? v.decode(as: SpeedTestResult.self) else { return v.pretty() }
        var s = r.headline
        if let g = r.gainPercent { s += String(format: "\nCombined is %+.0f%% vs the best single link.", g) }
        s += String(format: "\nData used: %.1f MB. %@", r.megabytesUsed, r.note)
        return s
    }
case "wifi":
    switch rest.first {
    case "on": run(.setWiFiPower, ["on": .bool(true)])
    case "off": run(.setWiFiPower, ["on": .bool(false)])
    case "disconnect": run(.disconnectWiFi)
    default: fail("usage: ply wifi on|off|disconnect", code: 2)
    }
case "settings":
    if rest.first == "set" {
        var p: Params = [:]
        for kv in rest.dropFirst() {
            let parts = kv.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { fail("expected key=value, got \(kv)", code: 2) }
            p[parts[0]] = parseValue(parts[1])
        }
        guard !p.isEmpty else { fail("usage: ply settings set key=value ...", code: 2) }
        run(.updateSettings, p)
    } else {
        run(.getSettings)
    }
case "repair":
    run(.repairTether)
case "restore-proxies":
    run(.restoreProxies)
case "helper":
    switch rest.first {
    case "install": run(.installHelper)
    case "uninstall": run(.uninstallHelper)
    case "status", nil: run(.status) { v in (v["helper"] ?? .null).pretty() }
    default: fail("usage: ply helper install|uninstall|status", code: 2)
    }
case "login-item":
    switch rest.first {
    case "on": run(.setLaunchAtLogin, ["on": .bool(true)])
    case "off": run(.setLaunchAtLogin, ["on": .bool(false)])
    default: fail("usage: ply login-item on|off", code: 2)
    }
case "agent-prompt":
    run(.agentPrompt) { v in v["prompt"]?.stringValue ?? v.pretty() }
case "open":
    run(.showWindow)
case "about":
    run(.about)
case "quit":
    run(.quit)
case "actions":
    if json { print(Docs.actionsJSON().pretty()) } else {
        for a in Registry.all { print("\(a.id.rawValue.padding(toLength: 20, withPad: " ", startingAt: 0)) \(a.cli)") }
    }
    exit(0)
case "action":
    guard let raw = rest.first, let id = ActionID(rawValue: raw) else {
        fail("usage: ply action <id> ['{json params}']. ids: \(ActionID.allCases.map(\.rawValue).joined(separator: ", "))", code: 2)
    }
    var p: Params = [:]
    if rest.count > 1 {
        guard let obj = (try? JSONValue.parse(Data(rest[1].utf8)))?.objectValue else { fail("params must be a JSON object", code: 2) }
        p = obj
    }
    run(id, p)
case "mcp":
    MCPServer.runStdio()
case "daemon":
    Log.echoToStderr = true
    if let h = try? block({ await APIClient().health() }) {
        fail("A Ply engine is already running (\(h.engine)).")
    }
    let engine = Engine(mode: .daemon)
    let api = APIServer(engine: engine)
    do { try api.start() } catch { fail("\(error)") }
    engine.start()
    for sig in [SIGINT, SIGTERM, SIGHUP] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler {
            Log.info("stopping")
            engine.stop()
            exit(0)
        }
        src.resume()
        signalSources.append(src)
    }
    Log.info("ply daemon \(PlyInfo.version) on 127.0.0.1:\(PlyInfo.apiPort)")
    dispatchMain()
case "docs":
    switch rest.first {
    case "llms": print(Docs.llmsTxt(), terminator: "")
    case "llms-full": print(Docs.llmsFullTxt(), terminator: "")
    case "skill": print(Docs.skillMarkdown(), terminator: "")
    case "write":
        let repo = URL(fileURLWithPath: rest.count > 1 ? rest[1] : FileManager.default.currentDirectoryPath)
        do { for f in try Docs.write(repo: repo) { print("wrote \(f)") } } catch { fail("\(error)") }
    default: fail("usage: ply docs llms|llms-full|skill|write [repo]", code: 2)
    }
    exit(0)
case "version", "--version", "-v":
    print(PlyInfo.version)
case "help", "--help", "-h":
    print(usage)
default:
    fail("unknown command \(command)\n\n\(usage)", code: 2)
}
