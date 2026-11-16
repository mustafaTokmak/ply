import Foundation

/// Every action a person can take in Ply. The menu bar UI, the HTTP API, the CLI
/// and the MCP server are all generated from this one list, and a test fails the
/// build if the UI ever triggers something that is not here.
public enum ActionID: String, CaseIterable, Codable, Sendable {
    case status
    case diagnose
    case agentPrompt = "agent_prompt"
    case preferUSB = "prefer_usb"
    case combineStart = "combine_start"
    case combineStop = "combine_stop"
    case speedTest = "speed_test"
    case setWiFiPower = "set_wifi_power"
    case disconnectWiFi = "disconnect_wifi"
    case getSettings = "get_settings"
    case updateSettings = "update_settings"
    case repairTether = "repair_tether"
    case restoreProxies = "restore_proxies"
    case installHelper = "install_helper"
    case uninstallHelper = "uninstall_helper"
    case setLaunchAtLogin = "set_launch_at_login"
    case showWindow = "show_window"
    case about
    case quit
}

public enum ParamType: Sendable, Equatable {
    case bool, integer, string, stringArray
    case enumeration([String])

    public var label: String {
        switch self {
        case .bool: return "boolean"
        case .integer: return "integer"
        case .string: return "string"
        case .stringArray: return "string[]"
        case .enumeration(let v): return v.joined(separator: "|")
        }
    }

    func accepts(_ v: JSONValue) -> Bool {
        switch (self, v) {
        case (.bool, .bool): return true
        case (.integer, .number(let n)): return n.rounded() == n
        case (.string, .string): return true
        case (.stringArray, .array(let a)): return a.allSatisfy { $0.stringValue != nil }
        case (.enumeration(let opts), .string(let s)): return opts.contains(s)
        default: return false
        }
    }

    var schema: JSONValue {
        switch self {
        case .bool: return .object(["type": .string("boolean")])
        case .integer: return .object(["type": .string("integer")])
        case .string: return .object(["type": .string("string")])
        case .stringArray: return .object(["type": .string("array"), "items": .object(["type": .string("string")])])
        case .enumeration(let opts): return .object(["type": .string("string"), "enum": .array(opts.map { .string($0) })])
        }
    }
}

public struct ParamSpec: Sendable {
    public let name: String
    public let type: ParamType
    public let required: Bool
    public let summary: String
}

/// Where an action can run when no Ply engine is running yet.
public enum ActionHost: String, Sendable {
    /// Runs anywhere, including a one-shot CLI/MCP call with no app open.
    case anywhere
    /// Needs a long-running engine (the app or `ply daemon`); clients start one if needed.
    case engine
    /// Needs the menu bar app itself.
    case app
}

public struct ActionSpec: Sendable {
    public let id: ActionID
    public let title: String
    public let summary: String
    public let params: [ParamSpec]
    public let readOnly: Bool
    public let host: ActionHost
    public let cli: String

    public var mcpName: String { "ply_" + id.rawValue }
    public var apiPath: String { "/v1/actions/" + id.rawValue }

    public var inputSchema: JSONValue {
        var props: [String: JSONValue] = [:]
        for p in params {
            var s = p.type.schema.objectValue ?? [:]
            s["description"] = .string(p.summary)
            props[p.name] = .object(s)
        }
        let required = params.filter(\.required).map { JSONValue.string($0.name) }
        var schema: [String: JSONValue] = ["type": .string("object"), "properties": .object(props), "additionalProperties": .bool(false)]
        if !required.isEmpty { schema["required"] = .array(required) }
        return .object(schema)
    }
}

public enum Registry {
    public static let all: [ActionSpec] = [
        ActionSpec(id: .status, title: "Status",
                   summary: "Which connection the Mac is using right now, every link with its live speed, the macOS service order, Combine state, helper state and findings.",
                   params: [], readOnly: true, host: .anywhere, cli: "ply status [--json|--md]"),
        ActionSpec(id: .diagnose, title: "Diagnose",
                   summary: "Explain why iPhone USB or Combine is not working and how to fix it. Each finding names the action that fixes it and includes a ready-to-paste agent prompt.",
                   params: [], readOnly: true, host: .anywhere, cli: "ply diagnose [--json]"),
        ActionSpec(id: .agentPrompt, title: "Copy agent prompt",
                   summary: "A self-contained prompt that describes this Mac's connection state and how to drive Ply, for pasting into any AI agent.",
                   params: [], readOnly: true, host: .anywhere, cli: "ply agent-prompt"),
        ActionSpec(id: .preferUSB, title: "Put iPhone USB first",
                   summary: "Move every iPhone USB network service above Wi-Fi in macOS's service order and turn off macOS's \"Disable unless needed\" switch for it, so the cable is used whenever it is connected. Needs the helper.",
                   params: [], readOnly: false, host: .anywhere, cli: "ply prefer-usb"),
        ActionSpec(id: .combineStart, title: "Combine Wi-Fi + iPhone",
                   summary: "Start Combine: a local proxy on 127.0.0.1:7591 spreads new connections across every link with internet (Wi-Fi, iPhone USB, Ethernet) and, with systemProxy, points macOS's auto-proxy at it. A single download stays on one link; many connections add up.",
                   params: [
                    ParamSpec(name: "split", type: .enumeration(SplitMode.allCases.map(\.rawValue)), required: false, summary: "connection (fastest) or site (one link per site). Saved as the split setting."),
                    ParamSpec(name: "systemProxy", type: .bool, required: false, summary: "Override the systemProxy setting for this run."),
                   ], readOnly: false, host: .engine, cli: "ply combine on [--split connection|site] [--no-system-proxy]"),
        ActionSpec(id: .combineStop, title: "Stop combining",
                   summary: "Stop Combine and restore the proxy settings Ply changed.",
                   params: [], readOnly: false, host: .anywhere, cli: "ply combine off"),
        ActionSpec(id: .speedTest, title: "Speed test",
                   summary: "Measure download speed on each link alone and on all links at once. Uses mobile data on the iPhone link (capped by speedTestMaxMB per link per phase).",
                   params: [
                    ParamSpec(name: "seconds", type: .integer, required: false, summary: "Seconds per phase, 2 to 15. Default 5."),
                    ParamSpec(name: "mode", type: .enumeration(["each", "combined", "both"]), required: false, summary: "each = every link alone, combined = all links together, both (default)."),
                   ], readOnly: true, host: .anywhere, cli: "ply speedtest [--seconds 5] [--mode both]"),
        ActionSpec(id: .setWiFiPower, title: "Wi-Fi power",
                   summary: "Turn the Mac's Wi-Fi radio on or off.",
                   params: [ParamSpec(name: "on", type: .bool, required: true, summary: "true to turn Wi-Fi on, false to turn it off.")],
                   readOnly: false, host: .anywhere, cli: "ply wifi on|off"),
        ActionSpec(id: .disconnectWiFi, title: "Leave Wi-Fi network",
                   summary: "Disconnect Wi-Fi from its current network (for example the iPhone's own Wi-Fi hotspot) without turning Wi-Fi off.",
                   params: [], readOnly: false, host: .anywhere, cli: "ply wifi disconnect"),
        ActionSpec(id: .getSettings, title: "Settings",
                   summary: "Read Ply's settings.",
                   params: [], readOnly: true, host: .anywhere, cli: "ply settings"),
        ActionSpec(id: .updateSettings, title: "Change settings",
                   summary: "Change one or more settings. Pass only the keys to change.",
                   params: Settings.fields.map { ParamSpec(name: $0.key, type: $0.type, required: false, summary: $0.summary) },
                   readOnly: false, host: .anywhere, cli: "ply settings set key=value [key=value ...]"),
        ActionSpec(id: .repairTether, title: "Repair iPhone USB",
                   summary: "Turn each iPhone USB network service off and on again to wake a tether that is plugged in but not getting an address. Needs the helper.",
                   params: [], readOnly: false, host: .anywhere, cli: "ply repair"),
        ActionSpec(id: .restoreProxies, title: "Restore proxy settings",
                   summary: "Put back every macOS proxy setting Ply changed. Safe to run any time.",
                   params: [], readOnly: false, host: .anywhere, cli: "ply restore-proxies"),
        ActionSpec(id: .installHelper, title: "Install helper",
                   summary: "Install Ply's small root helper and the `ply` command (asks for an admin password once). The helper can only reorder network services, point proxies at Ply's local PAC file, restore them, and toggle one service.",
                   params: [], readOnly: false, host: .anywhere, cli: "ply helper install (or: sudo ply helper install)"),
        ActionSpec(id: .uninstallHelper, title: "Uninstall helper",
                   summary: "Restore proxies, then remove the helper, its LaunchDaemon and the /usr/local/bin/ply link.",
                   params: [], readOnly: false, host: .anywhere, cli: "ply helper uninstall"),
        ActionSpec(id: .setLaunchAtLogin, title: "Open at login",
                   summary: "Start the Ply menu bar app when you log in.",
                   params: [ParamSpec(name: "on", type: .bool, required: true, summary: "true to open at login.")],
                   readOnly: false, host: .app, cli: "ply login-item on|off"),
        ActionSpec(id: .showWindow, title: "Open Ply window",
                   summary: "Open Ply's window on the user's screen, with the same controls as the menu bar menu. Use it to show the user what Ply is doing, or when the menu bar icon is hidden because the menu bar is full (common on MacBooks with a notch). Opens Ply.app first if it is not running.",
                   params: [], readOnly: false, host: .app, cli: "ply open"),
        ActionSpec(id: .about, title: "About Ply",
                   summary: "Version, license, source code and documentation links.",
                   params: [], readOnly: true, host: .anywhere, cli: "ply about"),
        ActionSpec(id: .quit, title: "Quit Ply",
                   summary: "Stop the running Ply engine (app or daemon), restoring any proxy settings first.",
                   params: [], readOnly: false, host: .anywhere, cli: "ply quit"),
    ]

    public static func spec(_ id: ActionID) -> ActionSpec {
        guard let s = all.first(where: { $0.id == id }) else { preconditionFailure("missing spec for \(id)") }
        return s
    }

    public static func action(mcpName: String) -> ActionID? {
        all.first { $0.mcpName == mcpName }?.id
    }

    public static func validate(_ id: ActionID, _ params: Params) throws {
        let spec = spec(id)
        let names = spec.params.map(\.name)
        for (k, v) in params {
            guard let p = spec.params.first(where: { $0.name == k }) else {
                let valid = names.isEmpty ? "it takes no parameters" : "valid: \(names.joined(separator: ", "))"
                throw PlyError.badRequest("Unknown parameter '\(k)' for \(id.rawValue) (\(valid)).")
            }
            guard p.type.accepts(v) else {
                throw PlyError.badRequest("Parameter '\(k)' for \(id.rawValue) must be \(p.type.label).")
            }
        }
        for p in spec.params where p.required && params[p.name] == nil {
            throw PlyError.badRequest("Missing required parameter '\(p.name)' for \(id.rawValue).")
        }
    }
}
