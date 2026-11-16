import Foundation
import PlyShared

/// Talks to the root helper over its Unix socket.
public final class HelperClient: @unchecked Sendable {
    public init() {}

    public var isInstalled: Bool { FileManager.default.fileExists(atPath: PlyInfo.helperInstallPath) }

    @discardableResult
    public func send(_ req: HelperRequest, timeout: TimeInterval = 10) throws -> HelperResponse {
        let fd: Int32
        do { fd = try UnixSocket.connect(PlyInfo.helperSocketPath, timeout: timeout) } catch {
            throw isInstalled ? PlyError.failed("The Ply helper is installed but not answering (\(error)). Reinstall it with `ply helper install`.")
                              : PlyError.needsHelper("This needs the Ply helper. Install it once with `ply helper install` (asks for an admin password).")
        }
        defer { close(fd) }
        var data = try JSONEncoder().encode(req)
        data.append(0x0A)
        try UnixSocket.writeAll(fd, data)
        guard let line = try UnixSocket.readLine(fd, max: 1 << 20) else { throw PlyError.failed("The helper closed the connection.") }
        let resp = try JSONDecoder().decode(HelperResponse.self, from: line)
        if !resp.ok { throw PlyError.failed("Helper: \(resp.error ?? "unknown error")") }
        return resp
    }

    public func version() -> String? {
        guard isInstalled else { return nil }
        return (try? send(HelperRequest(op: HelperOp.version), timeout: 2))?.info?["version"]
    }

    public func setOrder(_ ids: [String]) throws { try send(HelperRequest(op: HelperOp.setOrder, serviceIDs: ids)) }
    public func setPAC(_ ids: [String], url: String) throws { try send(HelperRequest(op: HelperOp.setPAC, serviceIDs: ids, url: url)) }
    @discardableResult
    public func restoreProxies() throws -> Int { Int(try send(HelperRequest(op: HelperOp.restoreProxies)).info?["restored"] ?? "0") ?? 0 }
    public func setEnabled(_ id: String, _ on: Bool) throws { try send(HelperRequest(op: HelperOp.setEnabled, serviceID: id, enabled: on)) }
    /// Turns off "Disable unless needed" so these services stay active while Wi-Fi is connected.
    public func keepActive(_ ids: [String]) throws { try send(HelperRequest(op: HelperOp.keepActive, serviceIDs: ids)) }
}

/// Installs the helper as a LaunchDaemon. Uses an admin prompt (osascript), or runs directly under sudo.
public enum HelperInstaller {
    static var executableURL: URL {
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }

    /// The `Ply.app/Contents` folder, if we are running from inside the app bundle.
    static var bundleContents: URL? {
        var u = executableURL.deletingLastPathComponent()
        for _ in 0..<3 {
            if u.lastPathComponent == "Contents", u.deletingLastPathComponent().pathExtension == "app" { return u }
            u = u.deletingLastPathComponent()
        }
        return nil
    }

    public static func helperBinary() -> URL? {
        var candidates: [URL] = []
        if let c = bundleContents { candidates.append(c.appendingPathComponent("Library/LaunchServices/\(PlyInfo.helperLabel)")) }
        candidates.append(executableURL.deletingLastPathComponent().appendingPathComponent("ply-helper"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static func cliBinary() -> URL? {
        var candidates: [URL] = []
        if let c = bundleContents { candidates.append(c.appendingPathComponent("Helpers/ply")) }
        candidates.append(executableURL.deletingLastPathComponent().appendingPathComponent("ply"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static let installScript = """
    #!/bin/sh
    set -e
    SRC="$1"
    CLI="$2"
    /bin/mkdir -p /Library/PrivilegedHelperTools "/Library/Application Support/Ply"
    /usr/bin/install -m 0755 -o root -g wheel "$SRC" /Library/PrivilegedHelperTools/app.ply.helper
    /usr/bin/xattr -c /Library/PrivilegedHelperTools/app.ply.helper 2>/dev/null || true
    /bin/cat > /Library/LaunchDaemons/app.ply.helper.plist <<'PLIST'
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key><string>app.ply.helper</string>
      <key>ProgramArguments</key><array><string>/Library/PrivilegedHelperTools/app.ply.helper</string></array>
      <key>RunAtLoad</key><true/>
      <key>KeepAlive</key><true/>
      <key>StandardErrorPath</key><string>/Library/Logs/ply-helper.log</string>
    </dict>
    </plist>
    PLIST
    /usr/sbin/chown root:wheel /Library/LaunchDaemons/app.ply.helper.plist
    /bin/chmod 0644 /Library/LaunchDaemons/app.ply.helper.plist
    /bin/launchctl bootout system/app.ply.helper 2>/dev/null || true
    /bin/launchctl bootstrap system /Library/LaunchDaemons/app.ply.helper.plist
    if [ -n "$CLI" ] && [ -x "$CLI" ]; then
      /bin/mkdir -p /usr/local/bin
      /bin/ln -sf "$CLI" /usr/local/bin/ply
    fi
    """

    static let uninstallScript = """
    #!/bin/sh
    /bin/launchctl bootout system/app.ply.helper 2>/dev/null || true
    /bin/rm -f /Library/LaunchDaemons/app.ply.helper.plist /Library/PrivilegedHelperTools/app.ply.helper /var/run/app.ply.helper.sock
    /bin/rm -rf "/Library/Application Support/Ply"
    if [ -L /usr/local/bin/ply ]; then
      case "$(/usr/bin/readlink /usr/local/bin/ply)" in *Ply.app/*|*/ply) /bin/rm -f /usr/local/bin/ply ;; esac
    fi
    exit 0
    """

    public static func install() throws -> Params {
        guard let helper = helperBinary() else {
            throw PlyError.unavailable("Cannot find the ply-helper binary next to this program or inside Ply.app.")
        }
        let cli = cliBinary()?.path ?? ""
        try runPrivileged(installScript, args: [helper.path, cli],
                          prompt: "Ply needs your password once to install its network helper.")
        for _ in 0..<20 {
            if HelperClient().version() != nil { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        let version = HelperClient().version()
        return ["installed": .bool(true), "running": .bool(version != nil), "version": version.map { .string($0) } ?? .null,
                "cli": cli.isEmpty ? .null : .string("/usr/local/bin/ply")]
    }

    public static func uninstall() throws -> Params {
        let helper = HelperClient()
        let restored = (try? helper.restoreProxies()) ?? 0
        try runPrivileged(uninstallScript, args: [], prompt: "Ply needs your password to remove its network helper.")
        return ["installed": .bool(false), "proxiesRestored": .number(Double(restored))]
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func runPrivileged(_ script: String, args: [String], prompt: String) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ply-\(UUID().uuidString).sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let command = (["/bin/sh", url.path] + args).map(shellQuote).joined(separator: " ")
        let process = Process()
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        if getuid() == 0 {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [url.path] + args
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "do shell script \(appleScriptString(command)) with administrator privileges with prompt \(appleScriptString(prompt))"]
        }
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if err.contains("-128") { throw PlyError.failed("Cancelled: no admin password was given.") }
            if err.contains("-60007") || err.contains("interaction") {
                throw PlyError.unavailable("No password dialog can be shown here (for example over SSH). Run `sudo ply helper install` in a terminal instead.")
            }
            throw PlyError.failed("Admin step failed: \(err.isEmpty ? "exit \(process.terminationStatus)" : err)")
        }
    }
}
