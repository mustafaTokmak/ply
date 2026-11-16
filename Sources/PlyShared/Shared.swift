import Foundation
import SystemConfiguration

/// Names, paths and ports shared by the app, the CLI and the root helper.
public enum PlyInfo {
    public static let name = "Ply"
    public static let version = "0.1.1"
    public static let bundleID = "app.ply.Ply"
    public static let repoURL = "https://github.com/mustafaTokmak/ply"

    public static let helperLabel = "app.ply.helper"
    public static let helperSocketPath = "/var/run/app.ply.helper.sock"
    public static let helperInstallPath = "/Library/PrivilegedHelperTools/app.ply.helper"
    public static let helperPlistPath = "/Library/LaunchDaemons/app.ply.helper.plist"
    public static let helperDataDir = "/Library/Application Support/Ply"
    public static let helperBackupPath = "/Library/Application Support/Ply/proxies-backup.plist"

    /// Local HTTP API (and PAC file) port. "PLY" on a phone keypad is 759.
    public static let apiPort: UInt16 = 7590
    /// Local SOCKS5 / HTTP CONNECT proxy used by Combine mode.
    public static let proxyPort: UInt16 = 7591

    public static var pacURL: String { "http://127.0.0.1:\(apiPort)/proxy.pac" }
}

// MARK: - Helper protocol (one JSON object per line over a Unix socket)

public enum HelperOp {
    public static let version = "version"
    /// Reorder network services. `serviceIDs` is the wanted order (a permutation of existing services).
    public static let setOrder = "set_order"
    /// Point the services' auto-proxy (PAC) at Ply's local PAC URL. Original settings are backed up.
    public static let setPAC = "set_pac"
    /// Put back every proxy setting Ply changed.
    public static let restoreProxies = "restore_proxies"
    /// Enable or disable one network service (used to wake a stuck iPhone USB tether).
    public static let setEnabled = "set_enabled"
    /// Turn off macOS's "Disable unless needed" switch for the given services, so iPhone USB
    /// stays active while Wi-Fi is connected. (It can only turn the switch off, never on.)
    public static let keepActive = "keep_active"
}

/// macOS's per-interface "Disable unless needed" switch (System Settings > Network > iPhone USB > Details).
/// When it is on, macOS keeps the interface idle while any other network works. Apple's configd stores it as
/// `DisableUntilNeeded` (0 or 1) in `/Sets/<set>/Network/Interface/<bsd>`, and when the key is missing it
/// defaults to ON for tethered phones (SCNetworkInterfaceGetDisableUntilNeeded in configd's SCNetworkInterface.c).
public enum DisableUntilNeeded {
    public static let key = "DisableUntilNeeded"

    public static func path(setID: String, bsd: String) -> String { "/Sets/\(setID)/Network/Interface/\(bsd)" }

    /// The stored value: true/false, or nil when macOS uses its default.
    public static func stored(prefs: SCPreferences, setID: String, bsd: String) -> Bool? {
        guard let dict = SCPreferencesPathGetValue(prefs, path(setID: setID, bsd: bsd) as CFString) as? [String: Any],
              let n = dict[key] as? NSNumber else { return nil }
        return n.intValue != 0
    }

    /// What macOS does: the stored value, else on for phone tethers.
    public static func effective(stored: Bool?, isTether: Bool) -> Bool { stored ?? isTether }

    /// Turns the switch off for one interface in every set that has the service, the same way System Settings does
    /// (Apple's SCNetworkInterfaceSetDisableUntilNeeded). Falls back to writing the per-set path directly.
    /// The caller must hold the preferences lock and commit/apply afterwards.
    public static func turnOff(prefs: SCPreferences, interface: SCNetworkInterface, setIDs: [String], bsd: String) -> Bool {
        typealias SetFn = @convention(c) (SCNetworkInterface, DarwinBoolean) -> DarwinBoolean
        if let handle = dlopen("/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration", RTLD_NOW),
           let sym = dlsym(handle, "SCNetworkInterfaceSetDisableUntilNeeded") {
            let fn = unsafeBitCast(sym, to: SetFn.self)
            if fn(interface, false).boolValue { return true }
        }
        var ok = !setIDs.isEmpty
        for setID in setIDs {
            let p = path(setID: setID, bsd: bsd) as CFString
            var dict = (SCPreferencesPathGetValue(prefs, p) as? [String: Any]) ?? [:]
            dict[key] = 0
            if !SCPreferencesPathSetValue(prefs, p, dict as CFDictionary) { ok = false }
        }
        return ok
    }
}

public struct HelperRequest: Codable, Sendable {
    public var op: String
    public var serviceIDs: [String]?
    public var serviceID: String?
    public var url: String?
    public var enabled: Bool?

    public init(op: String, serviceIDs: [String]? = nil, serviceID: String? = nil, url: String? = nil, enabled: Bool? = nil) {
        self.op = op
        self.serviceIDs = serviceIDs
        self.serviceID = serviceID
        self.url = url
        self.enabled = enabled
    }
}

public struct HelperResponse: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var info: [String: String]?

    public init(ok: Bool, error: String? = nil, info: [String: String]? = nil) {
        self.ok = ok
        self.error = error
        self.info = info
    }
}

/// The helper only ever points system proxies at Ply's own local PAC URL.
public enum PACURLPolicy {
    public static func isAllowed(_ url: String) -> Bool {
        let prefix = "http://127.0.0.1:"
        let suffix = "/proxy.pac"
        guard url.hasPrefix(prefix), url.hasSuffix(suffix), url.count > prefix.count + suffix.count else { return false }
        let middle = url.dropFirst(prefix.count).dropLast(suffix.count)
        guard middle.allSatisfy(\.isNumber), let port = Int(middle), (1024...65535).contains(port) else { return false }
        return true
    }
}

// MARK: - Minimal blocking Unix-socket helpers

public enum UnixSocket {
    public struct SocketError: Error, CustomStringConvertible {
        public let description: String
        public init(_ d: String) { description = d }
    }

    static func makeAddress(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw SocketError("socket path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        return addr
    }

    public static func connect(_ path: String, timeout: TimeInterval) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError("socket() failed: \(errno)") }
        setTimeout(fd, timeout)
        var addr = try makeAddress(path)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
        if rc != 0 {
            let e = errno
            close(fd)
            throw SocketError("cannot connect to \(path): \(String(cString: strerror(e)))")
        }
        return fd
    }

    public static func listen(_ path: String, mode: mode_t) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError("socket() failed: \(errno)") }
        var addr = try makeAddress(path)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard rc == 0 else { throw SocketError("bind(\(path)) failed: \(String(cString: strerror(errno)))") }
        chmod(path, mode)
        guard Darwin.listen(fd, 16) == 0 else { throw SocketError("listen failed: \(errno)") }
        return fd
    }

    public static func setTimeout(_ fd: Int32, _ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    public static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let n = write(fd, base + sent, raw.count - sent)
                if n <= 0 { throw SocketError("write failed: \(errno)") }
                sent += n
            }
        }
    }

    /// Reads up to the first newline. Returns nil if the peer closed before sending anything.
    public static func readLine(_ fd: Int32, max: Int) throws -> Data? {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while out.count < max {
            let n = read(fd, &buf, buf.count)
            if n < 0 { throw SocketError("read failed: \(errno)") }
            if n == 0 { break }
            out.append(contentsOf: buf[0..<n])
            if let nl = out.firstIndex(of: 0x0A) { return out.subdata(in: out.startIndex..<nl) }
        }
        return out.isEmpty ? nil : out
    }
}
