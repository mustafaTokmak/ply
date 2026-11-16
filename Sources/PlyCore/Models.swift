import Foundation
import PlyShared

public enum LinkKind: String, Codable, Sendable {
    case wifi, tether, ethernet, other
}

/// A configured macOS network service, in service-order position.
public struct ServiceInfo: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var bsd: String?
    public var kind: LinkKind
    public var enabled: Bool
    /// macOS's "Disable unless needed" switch as it takes effect (stored value, else Apple's default:
    /// on for phone tethers). When true, macOS keeps this service idle while another network works.
    public var idleUnlessNeeded: Bool

    public init(id: String, name: String, bsd: String?, kind: LinkKind, enabled: Bool, idleUnlessNeeded: Bool = false) {
        self.id = id
        self.name = name
        self.bsd = bsd
        self.kind = kind
        self.enabled = enabled
        self.idleUnlessNeeded = idleUnlessNeeded
    }
}

/// Live state of one interface that could carry internet traffic.
public struct LinkState: Codable, Equatable, Sendable {
    public var bsd: String
    public var serviceID: String?
    public var serviceName: String?
    public var kind: LinkKind
    public var ipv4: [String]
    public var router: String?
    /// Has an IPv4 address and a router.
    public var up: Bool
    public var primary: Bool
    /// The router is 172.20.10.1, the address every iPhone Personal Hotspot uses.
    public var iphoneHotspot: Bool

    public init(bsd: String, serviceID: String?, serviceName: String?, kind: LinkKind, ipv4: [String], router: String?, up: Bool, primary: Bool, iphoneHotspot: Bool) {
        self.bsd = bsd
        self.serviceID = serviceID
        self.serviceName = serviceName
        self.kind = kind
        self.ipv4 = ipv4
        self.router = router
        self.up = up
        self.primary = primary
        self.iphoneHotspot = iphoneHotspot
    }

    public var displayName: String {
        switch kind {
        case .wifi: return iphoneHotspot ? "Wi-Fi (iPhone hotspot)" : "Wi-Fi"
        case .tether: return serviceName ?? "iPhone USB"
        default: return serviceName ?? bsd
        }
    }
}

public struct WiFiState: Codable, Equatable, Sendable {
    public var bsd: String?
    public var power: Bool?
    public var ssid: String?

    public init(bsd: String? = nil, power: Bool? = nil, ssid: String? = nil) {
        self.bsd = bsd
        self.power = power
        self.ssid = ssid
    }
}

public struct NetworkSnapshot: Codable, Equatable, Sendable {
    public var services: [ServiceInfo]
    public var links: [LinkState]
    public var primaryBSD: String?
    public var iphonesOnUSB: [String]
    public var wifi: WiFiState

    public init(services: [ServiceInfo], links: [LinkState], primaryBSD: String?, iphonesOnUSB: [String], wifi: WiFiState) {
        self.services = services
        self.links = links
        self.primaryBSD = primaryBSD
        self.iphonesOnUSB = iphonesOnUSB
        self.wifi = wifi
    }

    public static let empty = NetworkSnapshot(services: [], links: [], primaryBSD: nil, iphonesOnUSB: [], wifi: WiFiState())

    public var tetherUp: [LinkState] { links.filter { $0.kind == .tether && $0.up } }
    public var wifiLink: LinkState? { links.first { $0.kind == .wifi } }
    public var primary: LinkState? { links.first { $0.primary } }

    /// Links Combine can spread traffic over.
    public var combineCandidates: [LinkState] {
        links.filter { $0.up && [.wifi, .tether, .ethernet].contains($0.kind) }
    }
}

public struct Finding: Codable, Equatable, Sendable {
    public enum Severity: String, Codable, Sendable { case ok, info, warn, error }
    public var id: String
    public var severity: Severity
    public var title: String
    public var detail: String
    public var fix: ActionID?
    public var fixParams: Params?
    public var agentPrompt: String
}

public struct EngineEvent: Codable, Equatable, Sendable {
    public var at: Date
    public var message: String
}

public struct LinkReport: Codable, Equatable, Sendable {
    public var bsd: String
    public var name: String
    public var kind: LinkKind
    public var up: Bool
    public var primary: Bool
    public var iphoneHotspot: Bool
    public var ipv4: [String]
    public var router: String?
    /// Whole-interface throughput, bytes per second.
    public var rxBps: Double
    public var txBps: Double
}

public struct CombineLinkReport: Codable, Equatable, Sendable {
    public var bsd: String
    public var health: String
    public var activeFlows: Int
    public var totalFlows: Int
    public var bytesIn: UInt64
    public var bytesOut: UInt64
    public var inBps: Double
    public var outBps: Double
    public var failures: Int
}

public struct CombineReport: Codable, Equatable, Sendable {
    public var running: Bool
    public var autoStarted: Bool
    public var port: UInt16
    public var split: SplitMode
    public var systemProxy: Bool
    public var activeFlows: Int
    public var totalFlows: Int
    public var healthyLinks: Int
    public var links: [CombineLinkReport]
    public var warning: String?
}

public struct HelperReport: Codable, Equatable, Sendable {
    public var installed: Bool
    public var running: Bool
    public var version: String?
    public var needsUpdate: Bool
}

public struct USBReport: Codable, Equatable, Sendable {
    /// not-connected | plugged-in-no-hotspot | plugged-in-idle (macOS keeps it idle: "Disable unless needed") | active
    public var state: String
    public var iphones: [String]
    public var tetherUp: Bool
}

public struct WiFiReport: Codable, Equatable, Sendable {
    public var bsd: String?
    public var power: Bool?
    public var ssid: String?
    public var up: Bool
    public var onIPhoneHotspot: Bool
}

public struct StatusReport: Codable, Equatable, Sendable {
    public var app: String
    public var version: String
    /// app | daemon | passive (no Ply engine running; a one-shot read)
    public var engine: String
    public var summary: String
    public var primary: String?
    public var links: [LinkReport]
    public var usb: USBReport
    public var wifi: WiFiReport
    public var serviceOrder: [ServiceInfo]
    public var combine: CombineReport
    public var helper: HelperReport
    public var settings: Settings
    public var launchAtLogin: Bool?
    public var findings: [Finding]
    public var events: [EngineEvent]
    public var lastSpeedTest: SpeedTestResult?
    public var updatedAt: Date
}
