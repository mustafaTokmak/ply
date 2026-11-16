import Foundation
import PlyShared

/// Pure decisions, kept free of system calls so they can be unit-tested.
public enum ServiceOrder {
    /// The service order with every phone-tether service moved directly above the first
    /// Wi-Fi service, or nil when it is already right (or there is nothing to move).
    public static func usbFirst(_ services: [ServiceInfo]) -> [String]? {
        guard let firstWiFi = services.firstIndex(where: { $0.kind == .wifi }) else { return nil }
        let tether = services.filter { $0.kind == .tether }
        guard !tether.isEmpty else { return nil }
        let alreadyFirst = services.enumerated().allSatisfy { $0.element.kind != .tether || $0.offset < firstWiFi }
        if alreadyFirst { return nil }
        var rest = services.filter { $0.kind != .tether }.map(\.id)
        guard let insertAt = rest.firstIndex(of: services[firstWiFi].id) else { return nil }
        rest.insert(contentsOf: tether.map(\.id), at: insertAt)
        return rest
    }

    /// The reverse, for when "iPhone USB first" is turned off: every phone-tether service moved
    /// directly below the first Wi-Fi service, or nil when no tether service is above Wi-Fi.
    public static func wifiFirst(_ services: [ServiceInfo]) -> [String]? {
        guard let firstWiFi = services.firstIndex(where: { $0.kind == .wifi }) else { return nil }
        let above = services[..<firstWiFi].filter { $0.kind == .tether }
        guard !above.isEmpty else { return nil }
        var rest = services.filter { s in !above.contains { $0.id == s.id } }.map(\.id)
        guard let wifiAt = rest.firstIndex(of: services[firstWiFi].id) else { return nil }
        rest.insert(contentsOf: above.map(\.id), at: wifiAt + 1)
        return rest
    }
}

public struct DiagnosisInput: Sendable {
    public var snapshot: NetworkSnapshot
    public var settings: Settings
    public var helperInstalled: Bool
    public var helperRunning: Bool
    public var combineRunning: Bool
    public var combineHealthyLinks: Int
    public var engine: String

    public init(snapshot: NetworkSnapshot, settings: Settings, helperInstalled: Bool, helperRunning: Bool, combineRunning: Bool, combineHealthyLinks: Int, engine: String) {
        self.snapshot = snapshot
        self.settings = settings
        self.helperInstalled = helperInstalled
        self.helperRunning = helperRunning
        self.combineRunning = combineRunning
        self.combineHealthyLinks = combineHealthyLinks
        self.engine = engine
    }
}

public enum Diagnosis {
    public static func findings(_ i: DiagnosisInput) -> [Finding] {
        var out: [Finding] = []
        let s = i.snapshot
        let tetherUp = s.tetherUp
        let tetherServices = s.services.filter { $0.kind == .tether }
        let wifi = s.wifiLink

        func add(_ id: String, _ sev: Finding.Severity, _ title: String, _ detail: String, fix: ActionID? = nil, params: Params? = nil) {
            out.append(Finding(id: id, severity: sev, title: title, detail: detail, fix: fix, fixParams: params,
                               agentPrompt: prompt(title: title, detail: detail, fix: fix, params: params)))
        }

        if tetherUp.isEmpty {
            if s.iphonesOnUSB.isEmpty {
                add("no-iphone", .info, "No iPhone on USB",
                    "Connect the iPhone with a USB cable, unlock it and tap Trust if it asks. Then turn on Personal Hotspot on the iPhone.")
            } else if tetherServices.isEmpty {
                add("no-usb-service", .warn, "\(s.iphonesOnUSB[0]) is plugged in but macOS has no iPhone USB network service",
                    "Open System Settings > Network, click the ... button, choose Add Service, pick iPhone USB and click Create. Also make sure Personal Hotspot > Allow Others to Join is on.")
            } else if tetherServices.allSatisfy({ !$0.enabled }) {
                add("usb-service-disabled", .warn, "The iPhone USB network service is turned off",
                    "macOS has the iPhone USB service but it is disabled. Ply can turn it back on.",
                    fix: i.helperInstalled ? .repairTether : .installHelper)
            } else if let idle = tetherServices.first(where: { $0.enabled && $0.idleUnlessNeeded }), s.primary != nil {
                add("usb-idle-unless-needed", .warn, "macOS keeps \(idle.name) idle because another network works",
                    "\(idle.name) has macOS's \"Disable unless needed\" switch on (Apple's default for iPhone USB), so the Mac ignores the cable while Wi-Fi or Ethernet is connected. Ply can turn it off; you can also do it in System Settings > Network > \(idle.name) > Details.",
                    fix: i.helperInstalled ? .preferUSB : .installHelper)
            } else {
                add("hotspot-off", .warn, "\(s.iphonesOnUSB[0]) is plugged in but not sharing internet",
                    "On the iPhone open Settings > Personal Hotspot and turn on Allow Others to Join. Keep the iPhone unlocked while it connects. If it still does not connect, try Repair iPhone USB or another cable.",
                    fix: i.helperInstalled ? .repairTether : nil)
            }
        }

        // Only when the user wants the cable first; with preferUSB off, Wi-Fi first is what they asked for.
        if i.settings.preferUSB, !tetherUp.isEmpty, let primary = s.primary, primary.kind != .tether, ServiceOrder.usbFirst(s.services) != nil {
            add("wifi-first", .warn, "iPhone USB is connected but the Mac is using \(primary.displayName)",
                "macOS uses the first connected service in its service order, and \(primary.displayName) is above iPhone USB. Ply can move iPhone USB above Wi-Fi.",
                fix: i.helperInstalled ? .preferUSB : .installHelper)
        }

        if !tetherUp.isEmpty, let idle = tetherServices.first(where: { $0.enabled && $0.idleUnlessNeeded }) {
            add("usb-idle-unless-needed", .info, "\(idle.name) will go idle when Wi-Fi connects",
                "\(idle.name) has macOS's \"Disable unless needed\" switch on (Apple's default for iPhone USB). It works now, but macOS will stop using the cable as soon as Wi-Fi or Ethernet connects. Ply can turn the switch off.",
                fix: i.helperInstalled ? .preferUSB : .installHelper)
        }

        if !tetherUp.isEmpty, let wifi, wifi.up, wifi.iphoneHotspot, !i.combineRunning {
            add("wifi-on-iphone-hotspot", .info, "Wi-Fi is joined to an iPhone hotspot while USB is up",
                "Wi-Fi is connected to an iPhone's hotspot (router 172.20.10.1) although the cable already gives internet. Leaving it frees Wi-Fi for a real network.",
                fix: .disconnectWiFi)
        }

        if !i.helperInstalled {
            add("helper-missing", .info, "Helper not installed",
                "Moving iPhone USB above Wi-Fi and pointing apps at Combine change macOS network settings, which needs admin rights once. Install the helper to let Ply do it.",
                fix: .installHelper)
        } else if !i.helperRunning {
            add("helper-not-running", .warn, "Helper is installed but not answering",
                "Reinstall the helper. It is started by launchd as app.ply.helper.", fix: .installHelper)
        }

        if i.combineRunning && i.combineHealthyLinks < 2 {
            add("combine-one-link", .warn, "Combine is on but only \(i.combineHealthyLinks) link has internet",
                "Combine needs at least two links with internet, for example Wi-Fi plus iPhone USB. Traffic is using the working link only.")
        }

        if let wifi, wifi.up, wifi.iphoneHotspot, tetherUp.contains(where: { $0.iphoneHotspot }), i.combineRunning {
            add("same-phone", .info, "Both links may be the same iPhone",
                "Wi-Fi and USB both go through an iPhone hotspot. If it is the same iPhone, combining adds nothing; join a different Wi-Fi network.")
        }

        if out.allSatisfy({ $0.severity == .info || $0.severity == .ok }) {
            if let p = s.primary {
                let via = i.combineRunning && i.combineHealthyLinks >= 2 ? "combining \(i.combineHealthyLinks) links" : "using \(p.displayName)"
                out.insert(Finding(id: "ok", severity: .ok, title: "Internet is working, \(via)", detail: "Nothing needs fixing.", fix: nil, fixParams: nil,
                                   agentPrompt: prompt(title: "Internet is working, \(via)", detail: "Nothing needs fixing.", fix: nil, params: nil)), at: 0)
            } else {
                add("offline", .error, "No internet connection", "No Wi-Fi, Ethernet or iPhone USB link has an address and a router.")
            }
        }
        return out
    }

    static func prompt(title: String, detail: String, fix: ActionID?, params: Params?) -> String {
        var p = "On my Mac, the open-source app Ply (\(PlyInfo.repoURL)) reports: \"\(title)\". \(detail)"
        if let fix {
            let spec = Registry.spec(fix)
            let args = params.map { JSONValue.object($0).compact() } ?? "{}"
            p += " Fix it with Ply: run `\(spec.cli)` in Terminal, or call the MCP tool `\(spec.mcpName)` with \(args) from the Ply MCP server (`ply mcp`)."
        }
        p += " Then run `ply status --json` (or MCP `ply_status`) and confirm which link the Mac is using."
        return p
    }
}

public enum AgentPrompt {
    public static func make(_ r: StatusReport) -> String {
        let links = r.links.map { l in
            "- \(l.name) (\(l.bsd)): \(l.up ? "connected" : "not connected")\(l.primary ? ", primary" : "")\(l.ipv4.first.map { ", \($0)" } ?? "")"
        }.joined(separator: "\n")
        let findings = r.findings.map { "- [\($0.severity.rawValue)] \($0.title): \($0.detail)\($0.fix.map { " Fix: \($0.rawValue)." } ?? "")" }.joined(separator: "\n")
        return """
        You are helping me with my Mac's internet connection. I use Ply, an open-source macOS menu bar app (\(PlyInfo.repoURL)) that keeps the Mac on an iPhone's USB hotspot and can combine Wi-Fi + iPhone USB.

        Current state (\(ISO8601DateFormatter().string(from: r.updatedAt))):
        Summary: \(r.summary)
        Links:
        \(links.isEmpty ? "- none" : links)
        Combine: \(r.combine.running ? "on, \(r.combine.activeFlows) active connections over \(r.combine.healthyLinks) healthy links" : "off")
        Helper: \(r.helper.installed ? "installed" : "not installed")
        Findings:
        \(findings.isEmpty ? "- none" : findings)

        You can drive Ply three ways (all return JSON):
        1. Terminal: `ply status --json`, `ply diagnose --json`, `ply prefer-usb`, `ply combine on`, `ply combine off`, `ply speedtest`, `ply settings set key=value`.
        2. MCP: add the stdio server `ply mcp`; tools are named ply_<action>, e.g. ply_status, ply_combine_start.
        3. HTTP: POST http://127.0.0.1:\(PlyInfo.apiPort)/v1/actions/<action> with header "Authorization: Bearer $(cat ~/Library/Application\\ Support/Ply/api-token)".
        Full reference: \(PlyInfo.repoURL)/blob/main/docs/llms-full.txt

        Start by running `ply diagnose --json`, fix the findings in order, then confirm with `ply status --json`.
        """
    }
}
