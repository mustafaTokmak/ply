import Foundation
import SystemConfiguration
import IOKit
import CoreWLAN
import PlyShared

/// Reads macOS network state. Nothing here needs admin rights.
public enum NetworkInspector {
    public static let iphoneRouter = "172.20.10.1"

    public static func classify(interfaceType: String?, displayName: String?, serviceName: String?, bsd: String?, router: String?, extraTether: [String]) -> LinkKind {
        if let bsd, extraTether.contains(bsd) { return .tether }
        if interfaceType == (kSCNetworkInterfaceTypeIEEE80211 as String) { return .wifi }
        let names = [displayName, serviceName].compactMap { $0 }.joined(separator: " ").lowercased()
        if names.contains("iphone") || names.contains("ipad") { return .tether }
        if router == iphoneRouter, bsd?.hasPrefix("en") == true { return .tether }
        if interfaceType == (kSCNetworkInterfaceTypeEthernet as String), bsd?.hasPrefix("en") == true { return .ethernet }
        return .other
    }

    public static func snapshot(settings: Settings) -> NetworkSnapshot {
        let store = SCDynamicStoreCreate(nil, "app.ply.inspect" as CFString, nil, nil)
        func value(_ key: String) -> [String: Any]? {
            guard let store else { return nil }
            return SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
        }

        let global = value("State:/Network/Global/IPv4")
        let primaryBSD = global?["PrimaryInterface"] as? String

        // Configured services, in service order.
        var services: [ServiceInfo] = []
        var serviceMeta: [String: (type: String?, display: String?)] = [:]
        if let prefs = SCPreferencesCreate(nil, "app.ply.inspect" as CFString, nil),
           let set = SCNetworkSetCopyCurrent(prefs) {
            let all = (SCNetworkSetCopyServices(set) as? [SCNetworkService]) ?? []
            let order = (SCNetworkSetGetServiceOrder(set) as? [String]) ?? []
            let byID = Dictionary(all.map { ((SCNetworkServiceGetServiceID($0) as String?) ?? "", $0) }, uniquingKeysWith: { a, _ in a })
            let orderedIDs = order.filter { byID[$0] != nil } + byID.keys.filter { !order.contains($0) }.sorted()
            for id in orderedIDs {
                guard let svc = byID[id] else { continue }
                let name = (SCNetworkServiceGetName(svc) as String?) ?? id
                let iface = SCNetworkServiceGetInterface(svc)
                let bsd = iface.flatMap { SCNetworkInterfaceGetBSDName($0) as String? }
                let type = iface.flatMap { SCNetworkInterfaceGetInterfaceType($0) as String? }
                let display = iface.flatMap { SCNetworkInterfaceGetLocalizedDisplayName($0) as String? }
                serviceMeta[id] = (type, display)
                let router = value("State:/Network/Service/\(id)/IPv4")?["Router"] as? String
                let kind = classify(interfaceType: type, displayName: display, serviceName: name, bsd: bsd, router: router, extraTether: settings.tetherInterfaces)
                let setID = (SCNetworkSetGetSetID(set) as String?) ?? ""
                let stored = bsd.flatMap { DisableUntilNeeded.stored(prefs: prefs, setID: setID, bsd: $0) }
                // Apple's default (on) only applies to Apple's own phone tethers, not to extra tether interfaces.
                let appleTether = kind == .tether && [display, name].compactMap { $0?.lowercased() }.contains { $0.contains("iphone") || $0.contains("ipad") }
                services.append(ServiceInfo(id: id, name: name, bsd: bsd, kind: kind, enabled: SCNetworkServiceGetEnabled(svc),
                                            idleUnlessNeeded: DisableUntilNeeded.effective(stored: stored, isTether: appleTether)))
            }
        }

        // Live links: one per BSD interface that belongs to a wifi/tether/ethernet service.
        var links: [LinkState] = []
        var seen = Set<String>()
        for svc in services where [.wifi, .tether, .ethernet].contains(svc.kind) {
            guard let bsd = svc.bsd, !seen.contains(bsd) else { continue }
            let state = value("State:/Network/Service/\(svc.id)/IPv4")
            let ifaceState = value("State:/Network/Interface/\(bsd)/IPv4")
            let addrs = (state?["Addresses"] as? [String]) ?? (ifaceState?["Addresses"] as? [String]) ?? []
            let router = state?["Router"] as? String
            let active = !addrs.isEmpty && router != nil
            // Several services can share one interface; prefer the one that is live.
            if !active, services.contains(where: { $0.bsd == bsd && $0.id != svc.id && value("State:/Network/Service/\($0.id)/IPv4") != nil }) { continue }
            seen.insert(bsd)
            links.append(LinkState(bsd: bsd, serviceID: svc.id, serviceName: svc.name, kind: svc.kind, ipv4: addrs, router: router,
                                   up: active, primary: bsd == primaryBSD && active, iphoneHotspot: router == iphoneRouter))
        }

        return NetworkSnapshot(services: services, links: links, primaryBSD: primaryBSD,
                               iphonesOnUSB: USBDevices.connectedIOSDevices(), wifi: WiFiControl.state())
    }
}

/// iPhones and iPads on USB (whether or not they are sharing internet).
public enum USBDevices {
    public static func connectedIOSDevices() -> [String] {
        var names: [String] = []
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return names }
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else { return names }
        defer { IOObjectRelease(iter) }
        while true {
            let dev = IOIteratorNext(iter)
            if dev == 0 { break }
            defer { IOObjectRelease(dev) }
            let vendor = (IORegistryEntryCreateCFProperty(dev, "idVendor" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
            let product = IORegistryEntryCreateCFProperty(dev, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            if vendor == 0x05AC, let product, product.contains("iPhone") || product.contains("iPad") {
                names.append(product)
            }
        }
        return names
    }
}

public enum WiFiControl {
    static var interface: CWInterface? { CWWiFiClient.shared().interface() }

    public static func state() -> WiFiState {
        guard let i = interface else { return WiFiState() }
        return WiFiState(bsd: i.interfaceName, power: i.powerOn(), ssid: i.ssid())
    }

    public static func setPower(_ on: Bool) throws {
        guard let i = interface else { throw PlyError.unavailable("This Mac has no Wi-Fi interface.") }
        do { try i.setPower(on) } catch { throw PlyError.failed("Could not turn Wi-Fi \(on ? "on" : "off"): \(error.localizedDescription)") }
    }

    public static func disassociate() throws {
        guard let i = interface else { throw PlyError.unavailable("This Mac has no Wi-Fi interface.") }
        i.disassociate()
    }
}

/// Per-interface byte counters from getifaddrs (32-bit counters, so wraps are handled).
final class CounterSampler {
    private var last: [String: (rx: UInt64, tx: UInt64, t: TimeInterval)] = [:]
    private(set) var rates: [String: (rx: Double, tx: Double)] = [:]

    func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        let current = Self.read()
        for (name, c) in current {
            if let prev = last[name] {
                let dt = now - prev.t
                if dt > 0.2 {
                    rates[name] = (Double(Self.delta(c.rx, prev.rx)) / dt, Double(Self.delta(c.tx, prev.tx)) / dt)
                }
            }
            last[name] = (c.rx, c.tx, now)
        }
        for name in last.keys where current[name] == nil {
            last[name] = nil
            rates[name] = nil
        }
    }

    static func delta(_ new: UInt64, _ old: UInt64) -> UInt64 {
        if new >= old { return new - old }
        let wrapped = (new + (1 << 32)) &- old
        return wrapped < (1 << 31) ? wrapped : 0
    }

    static func read() -> [String: (rx: UInt64, tx: UInt64)] {
        var out: [String: (rx: UInt64, tx: UInt64)] = [:]
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return out }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let ifa = cur.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let data = ifa.ifa_data {
                let d = data.assumingMemoryBound(to: if_data.self).pointee
                out[String(cString: ifa.ifa_name)] = (UInt64(d.ifi_ibytes), UInt64(d.ifi_obytes))
            }
            p = ifa.ifa_next
        }
        return out
    }
}
