import Foundation

public enum SplitMode: String, Codable, CaseIterable, Sendable {
    /// Every new connection goes to the least-loaded link. Fastest; your IP can differ per connection.
    case connection
    /// All connections to one site stay on one link for 10 minutes. Safer for sites that tie logins to an IP.
    case site
}

public enum UIMode: String, Codable, CaseIterable, Sendable {
    /// Status and the two main switches.
    case simple
    /// Every setting, the per-link view and speed results.
    case advanced
}

public struct Settings: Codable, Equatable, Sendable {
    public var preferUSB = true
    public var leaveIPhoneWiFiWhenUSB = true
    public var wifiOffWhenUSB = false
    public var combineAuto = false
    public var split: SplitMode = .connection
    public var systemProxy = true
    public var tetherInterfaces: [String] = []
    public var speedTestURL = "https://speed.cloudflare.com/__down?bytes=25000000"
    public var speedTestMaxMB = 40
    public var uiMode: UIMode = .simple

    public init() {}

    enum CodingKeys: String, CodingKey, CaseIterable {
        case preferUSB, leaveIPhoneWiFiWhenUSB, wifiOffWhenUSB, combineAuto, split, systemProxy, tetherInterfaces, speedTestURL, speedTestMaxMB, uiMode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        preferUSB = try c.decodeIfPresent(Bool.self, forKey: .preferUSB) ?? d.preferUSB
        leaveIPhoneWiFiWhenUSB = try c.decodeIfPresent(Bool.self, forKey: .leaveIPhoneWiFiWhenUSB) ?? d.leaveIPhoneWiFiWhenUSB
        wifiOffWhenUSB = try c.decodeIfPresent(Bool.self, forKey: .wifiOffWhenUSB) ?? d.wifiOffWhenUSB
        combineAuto = try c.decodeIfPresent(Bool.self, forKey: .combineAuto) ?? d.combineAuto
        split = try c.decodeIfPresent(SplitMode.self, forKey: .split) ?? d.split
        systemProxy = try c.decodeIfPresent(Bool.self, forKey: .systemProxy) ?? d.systemProxy
        tetherInterfaces = try c.decodeIfPresent([String].self, forKey: .tetherInterfaces) ?? d.tetherInterfaces
        speedTestURL = try c.decodeIfPresent(String.self, forKey: .speedTestURL) ?? d.speedTestURL
        speedTestMaxMB = try c.decodeIfPresent(Int.self, forKey: .speedTestMaxMB) ?? d.speedTestMaxMB
        uiMode = try c.decodeIfPresent(UIMode.self, forKey: .uiMode) ?? d.uiMode
    }

    public struct Field: Sendable {
        public let key: String
        public let type: ParamType
        public let summary: String
    }

    /// The documented settings. Used for validation, docs, the API schema and the MCP schema.
    public static let fields: [Field] = [
        Field(key: "preferUSB", type: .bool, summary: "Keep iPhone USB above Wi-Fi in macOS's service order and turn off its \"Disable unless needed\" switch, so the cable wins whenever it is connected. Needs the helper. Default true."),
        Field(key: "leaveIPhoneWiFiWhenUSB", type: .bool, summary: "If the Mac joins the iPhone's Wi-Fi hotspot while USB is up, leave it (frees Wi-Fi for a real network). Skipped while combining. Default true."),
        Field(key: "wifiOffWhenUSB", type: .bool, summary: "Turn Wi-Fi off while iPhone USB is up and back on when it goes away. Ignored while combining. Default false."),
        Field(key: "combineAuto", type: .bool, summary: "Start Combine automatically when iPhone USB and another link (Wi-Fi or Ethernet) both have internet. Default false."),
        Field(key: "split", type: .enumeration(SplitMode.allCases.map(\.rawValue)), summary: "How Combine spreads traffic: 'connection' (fastest, per connection) or 'site' (one link per site for 10 minutes). Default connection."),
        Field(key: "systemProxy", type: .bool, summary: "While combining, point macOS's auto-proxy (PAC) at Ply so browsers and most apps use both links. Needs the helper. Default true."),
        Field(key: "tetherInterfaces", type: .stringArray, summary: "Extra BSD interface names (e.g. en9) to treat as a phone tether, for Android or other USB modems."),
        Field(key: "speedTestURL", type: .string, summary: "HTTPS download URL used by speed_test. Default is Cloudflare's speed endpoint."),
        Field(key: "speedTestMaxMB", type: .integer, summary: "Most megabytes speed_test may download per link per phase (mobile data). 5 to 500. Default 40."),
        Field(key: "uiMode", type: .enumeration(UIMode.allCases.map(\.rawValue)), summary: "How much the menu shows: 'simple' (status and the two main switches) or 'advanced' (every setting, each link and speed results). Default simple."),
    ]

    /// Applies a partial update. Unknown keys and wrong types are rejected with a readable message.
    public func merged(with patch: Params) throws -> Settings {
        let valid = Settings.fields.map(\.key)
        let unknown = patch.keys.filter { !valid.contains($0) }.sorted()
        if !unknown.isEmpty {
            throw PlyError.badRequest("Unknown setting(s): \(unknown.joined(separator: ", ")). Valid settings: \(valid.joined(separator: ", ")).")
        }
        var obj = (try JSONValue(encoding: self)).objectValue ?? [:]
        for (k, v) in patch { obj[k] = v }
        let next: Settings
        do {
            next = try JSONValue.object(obj).decode(as: Settings.self)
        } catch {
            throw PlyError.badRequest("Invalid setting value. Expected types: " + Settings.fields.map { "\($0.key)=\($0.type.label)" }.joined(separator: ", "))
        }
        guard (5...500).contains(next.speedTestMaxMB) else { throw PlyError.badRequest("speedTestMaxMB must be between 5 and 500") }
        guard let u = URL(string: next.speedTestURL), u.scheme == "https", u.host != nil else {
            throw PlyError.badRequest("speedTestURL must be an https:// URL")
        }
        guard next.tetherInterfaces.allSatisfy({ $0.range(of: "^[a-z]+[0-9]+$", options: .regularExpression) != nil }) else {
            throw PlyError.badRequest("tetherInterfaces must be BSD names like en9")
        }
        return next
    }
}

public enum SettingsStore {
    public static func load() -> Settings {
        guard let data = try? Data(contentsOf: Paths.settingsFile),
              let s = try? JSONCoding.decoder.decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    public static func save(_ s: Settings) throws {
        Paths.ensureDir()
        let data = try JSONCoding.prettyEncoder.encode(s)
        try data.write(to: Paths.settingsFile, options: .atomic)
    }
}
