// ply-helper: a tiny root LaunchDaemon with a fixed vocabulary.
//
// It can only: report its version, reorder existing network services, point
// services' auto-proxy at Ply's own 127.0.0.1 PAC URL (backing up the old
// settings), restore those proxy settings, enable/disable one existing
// service, and turn off "Disable unless needed" for existing services.
// It never runs shell commands. Only root and the console user may talk to it.

import Foundation
import SystemConfiguration
import PlyShared

setvbuf(stderr, nil, _IOLBF, 0)

func log(_ s: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    fputs("\(ts) \(s)\n", stderr)
}

guard getuid() == 0 else {
    fputs("ply-helper must run as root. It is installed by Ply.app (or `sudo ply helper install`) and started by launchd.\n", stderr)
    exit(1)
}

struct HelperFailure: Error { let message: String }

func scError() -> String { String(cString: SCErrorString(SCError())) }

func consoleUID() -> uid_t? {
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String?, name != "loginwindow" else { return nil }
    return uid
}

/// Runs `body` with locked SCPreferences, then commits and applies the changes.
func withNetworkPrefs<T>(_ body: (SCPreferences, SCNetworkSet) throws -> T) throws -> T {
    guard let prefs = SCPreferencesCreate(nil, "app.ply.helper" as CFString, nil) else {
        throw HelperFailure(message: "SCPreferencesCreate failed: \(scError())")
    }
    guard SCPreferencesLock(prefs, true) else { throw HelperFailure(message: "could not lock network preferences: \(scError())") }
    defer { SCPreferencesUnlock(prefs) }
    guard let set = SCNetworkSetCopyCurrent(prefs) else { throw HelperFailure(message: "no current network set") }
    let result = try body(prefs, set)
    guard SCPreferencesCommitChanges(prefs) else { throw HelperFailure(message: "commit failed: \(scError())") }
    guard SCPreferencesApplyChanges(prefs) else { throw HelperFailure(message: "apply failed: \(scError())") }
    return result
}

func services(of set: SCNetworkSet) -> [SCNetworkService] {
    (SCNetworkSetCopyServices(set) as? [SCNetworkService]) ?? []
}

func serviceID(_ s: SCNetworkService) -> String { (SCNetworkServiceGetServiceID(s) as String?) ?? "" }

func setOrder(_ wanted: [String]) throws -> [String: String] {
    guard !wanted.isEmpty, Set(wanted).count == wanted.count else { throw HelperFailure(message: "serviceIDs must be non-empty and unique") }
    return try withNetworkPrefs { _, set in
        let existing = Set(services(of: set).map(serviceID))
        let unknown = wanted.filter { !existing.contains($0) }
        guard unknown.isEmpty else { throw HelperFailure(message: "unknown service IDs: \(unknown.joined(separator: ", "))") }
        let current = (SCNetworkSetGetServiceOrder(set) as? [String]) ?? []
        let rest = current.filter { !wanted.contains($0) }
        let newOrder = wanted + rest
        guard SCNetworkSetSetServiceOrder(set, newOrder as CFArray) else { throw HelperFailure(message: "set order failed: \(scError())") }
        log("service order set: \(newOrder.joined(separator: ","))")
        return ["count": String(newOrder.count)]
    }
}

func loadBackup() -> [String: Any] {
    guard let data = FileManager.default.contents(atPath: PlyInfo.helperBackupPath),
          let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [:] }
    return obj
}

func saveBackup(_ dict: [String: Any]) throws {
    try FileManager.default.createDirectory(atPath: PlyInfo.helperDataDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    if dict.isEmpty {
        try? FileManager.default.removeItem(atPath: PlyInfo.helperBackupPath)
        return
    }
    let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    try data.write(to: URL(fileURLWithPath: PlyInfo.helperBackupPath), options: .atomic)
}

func proxiesProtocol(_ svc: SCNetworkService) -> SCNetworkProtocol? {
    if let p = SCNetworkServiceCopyProtocol(svc, kSCNetworkProtocolTypeProxies) { return p }
    _ = SCNetworkServiceAddProtocolType(svc, kSCNetworkProtocolTypeProxies)
    return SCNetworkServiceCopyProtocol(svc, kSCNetworkProtocolTypeProxies)
}

func setPAC(_ ids: [String], url: String) throws -> [String: String] {
    guard PACURLPolicy.isAllowed(url) else { throw HelperFailure(message: "refusing PAC URL \(url): only http://127.0.0.1:<port>/proxy.pac is allowed") }
    guard !ids.isEmpty else { throw HelperFailure(message: "no services given") }
    var backup = loadBackup()
    var changed: [String] = []
    try withNetworkPrefs { _, set in
        for svc in services(of: set) {
            let id = serviceID(svc)
            guard ids.contains(id), let proto = proxiesProtocol(svc) else { continue }
            let current = (SCNetworkProtocolGetConfiguration(proto) as? [String: Any]) ?? [:]
            if backup[id] == nil { backup[id] = current }
            var updated = current
            updated[kSCPropNetProxiesProxyAutoConfigEnable as String] = 1
            updated[kSCPropNetProxiesProxyAutoConfigURLString as String] = url
            guard SCNetworkProtocolSetConfiguration(proto, updated as CFDictionary) else {
                throw HelperFailure(message: "could not set proxies for \(id): \(scError())")
            }
            changed.append(id)
        }
    }
    try saveBackup(backup)
    log("PAC set on \(changed.count) service(s)")
    return ["changed": String(changed.count)]
}

func restoreProxies() throws -> [String: String] {
    let backup = loadBackup()
    guard !backup.isEmpty else { return ["restored": "0"] }
    var restored = 0
    try withNetworkPrefs { _, set in
        for svc in services(of: set) {
            let id = serviceID(svc)
            guard let original = backup[id] as? [String: Any], let proto = proxiesProtocol(svc) else { continue }
            if SCNetworkProtocolSetConfiguration(proto, original as CFDictionary) { restored += 1 }
        }
    }
    try saveBackup([:])
    log("proxies restored on \(restored) service(s)")
    return ["restored": String(restored)]
}

func setEnabled(_ id: String, _ enabled: Bool) throws -> [String: String] {
    try withNetworkPrefs { _, set in
        guard let svc = services(of: set).first(where: { serviceID($0) == id }) else {
            throw HelperFailure(message: "unknown service \(id)")
        }
        guard SCNetworkServiceSetEnabled(svc, enabled) else { throw HelperFailure(message: "could not change service: \(scError())") }
        log("service \(id) enabled=\(enabled)")
        return ["enabled": String(enabled)]
    }
}

func keepActive(_ ids: [String]) throws -> [String: String] {
    guard !ids.isEmpty, Set(ids).count == ids.count else { throw HelperFailure(message: "serviceIDs must be non-empty and unique") }
    return try withNetworkPrefs { prefs, set in
        let byID = Dictionary(services(of: set).map { (serviceID($0), $0) }, uniquingKeysWith: { a, _ in a })
        let unknown = ids.filter { byID[$0] == nil }
        guard unknown.isEmpty else { throw HelperFailure(message: "unknown service IDs: \(unknown.joined(separator: ", "))") }
        let allSets = (SCNetworkSetCopyAll(prefs) as? [SCNetworkSet]) ?? []
        var changed = 0
        for id in ids {
            guard let svc = byID[id], let iface = SCNetworkServiceGetInterface(svc),
                  let bsd = SCNetworkInterfaceGetBSDName(iface) as String? else {
                throw HelperFailure(message: "service \(id) has no network interface")
            }
            let setIDs = allSets.filter { s in services(of: s).contains { serviceID($0) == id } }
                .compactMap { SCNetworkSetGetSetID($0) as String? }
            guard DisableUntilNeeded.turnOff(prefs: prefs, interface: iface, setIDs: setIDs, bsd: bsd) else {
                throw HelperFailure(message: "could not change \"Disable unless needed\" for \(id): \(scError())")
            }
            changed += 1
        }
        log("\"Disable unless needed\" turned off for \(changed) service(s)")
        return ["changed": String(changed)]
    }
}

func handle(_ req: HelperRequest) -> HelperResponse {
    do {
        switch req.op {
        case HelperOp.version:
            return HelperResponse(ok: true, info: ["version": PlyInfo.version])
        case HelperOp.setOrder:
            return HelperResponse(ok: true, info: try setOrder(req.serviceIDs ?? []))
        case HelperOp.setPAC:
            return HelperResponse(ok: true, info: try setPAC(req.serviceIDs ?? [], url: req.url ?? ""))
        case HelperOp.restoreProxies:
            return HelperResponse(ok: true, info: try restoreProxies())
        case HelperOp.setEnabled:
            guard let id = req.serviceID, let on = req.enabled else { return HelperResponse(ok: false, error: "serviceID and enabled are required") }
            return HelperResponse(ok: true, info: try setEnabled(id, on))
        case HelperOp.keepActive:
            return HelperResponse(ok: true, info: try keepActive(req.serviceIDs ?? []))
        default:
            return HelperResponse(ok: false, error: "unknown op \(req.op)")
        }
    } catch let e as HelperFailure {
        return HelperResponse(ok: false, error: e.message)
    } catch {
        return HelperResponse(ok: false, error: "\(error)")
    }
}

signal(SIGPIPE, SIG_IGN)

let listenFD: Int32
do {
    listenFD = try UnixSocket.listen(PlyInfo.helperSocketPath, mode: 0o666)
} catch {
    log("cannot listen: \(error)")
    exit(1)
}
log("ply-helper \(PlyInfo.version) listening on \(PlyInfo.helperSocketPath)")

while true {
    let fd = accept(listenFD, nil, nil)
    if fd < 0 { continue }
    UnixSocket.setTimeout(fd, 10)
    var peerUID: uid_t = 0
    var peerGID: gid_t = 0
    let response: HelperResponse
    if getpeereid(fd, &peerUID, &peerGID) != 0 {
        response = HelperResponse(ok: false, error: "cannot identify caller")
    } else if peerUID != 0 && peerUID != consoleUID() {
        response = HelperResponse(ok: false, error: "only the logged-in console user may use ply-helper")
    } else if let line = try? UnixSocket.readLine(fd, max: 1 << 16),
              let req = try? JSONDecoder().decode(HelperRequest.self, from: line) {
        response = handle(req)
    } else {
        response = HelperResponse(ok: false, error: "bad request")
    }
    if var data = try? JSONEncoder().encode(response) {
        data.append(0x0A)
        try? UnixSocket.writeAll(fd, data)
    }
    close(fd)
}
