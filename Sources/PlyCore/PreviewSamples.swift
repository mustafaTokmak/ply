import Foundation
import PlyShared

/// Example states for UI previews and tests. The numbers are examples, not measurements.
public enum PreviewSamples {
    static func link(_ bsd: String, _ name: String, _ kind: LinkKind, primary: Bool, ip: String, rx: Double, tx: Double) -> LinkReport {
        LinkReport(bsd: bsd, name: name, kind: kind, up: true, primary: primary, iphoneHotspot: kind == .tether, ipv4: [ip],
                   router: kind == .tether ? "172.20.10.1" : "192.168.1.1", rxBps: rx, txBps: tx)
    }

    static func base(summary: String, links: [LinkReport], combine: CombineReport, findings: [Finding], settings: Settings = Settings(), speed: SpeedTestResult? = nil) -> StatusReport {
        StatusReport(app: "Ply", version: PlyInfo.version, engine: "app", summary: summary, primary: links.first { $0.primary }?.bsd, links: links,
                     usb: USBReport(state: "active", iphones: ["iPhone"], tetherUp: true),
                     wifi: WiFiReport(bsd: "en0", power: true, ssid: nil, up: true, onIPhoneHotspot: false),
                     serviceOrder: [], combine: combine, helper: HelperReport(installed: true, running: true, version: PlyInfo.version, needsUpdate: false),
                     settings: settings, launchAtLogin: true, findings: findings, events: [], lastSpeedTest: speed, updatedAt: Date())
    }

    static let combineOff = CombineReport(running: false, autoStarted: false, port: PlyInfo.proxyPort, split: .connection, systemProxy: false,
                                          activeFlows: 0, totalFlows: 0, healthyLinks: 0, links: [], warning: nil)

    public static func usbFirst() -> StatusReport {
        base(summary: "Internet via iPhone USB",
             links: [link("en7", "iPhone USB", .tether, primary: true, ip: "172.20.10.2", rx: 6_100_000, tx: 420_000),
                     link("en0", "Wi-Fi", .wifi, primary: false, ip: "192.168.1.70", rx: 0, tx: 0)],
             combine: combineOff, findings: [])
    }

    public static func combining() -> StatusReport {
        var s = Settings()
        s.combineAuto = true
        let speed = SpeedTestResult(startedAt: Date(), seconds: 5,
                                    each: [SpeedTestLinkResult(bsd: "en0", name: "Wi-Fi", mbps: 48.2, megabytes: 30.1, connectMs: 31, error: nil),
                                           SpeedTestLinkResult(bsd: "en7", name: "iPhone USB", mbps: 96.5, megabytes: 40, connectMs: 44, error: nil)],
                                    combined: [], combinedMbps: 139.7, bestSingleMbps: 96.5, gainPercent: 44.8, megabytesUsed: 150, note: "")
        let combine = CombineReport(running: true, autoStarted: true, port: PlyInfo.proxyPort, split: .connection, systemProxy: true,
                                    activeFlows: 23, totalFlows: 412, healthyLinks: 2,
                                    links: [CombineLinkReport(bsd: "en0", health: "ok", activeFlows: 8, totalFlows: 150, bytesIn: 1, bytesOut: 1, inBps: 5_400_000, outBps: 1, failures: 0),
                                            CombineLinkReport(bsd: "en7", health: "ok", activeFlows: 15, totalFlows: 262, bytesIn: 1, bytesOut: 1, inBps: 11_200_000, outBps: 1, failures: 0)],
                                    warning: nil)
        return base(summary: "Combining Wi-Fi + iPhone USB",
                    links: [link("en7", "iPhone USB", .tether, primary: true, ip: "172.20.10.2", rx: 11_300_000, tx: 650_000),
                            link("en0", "Wi-Fi", .wifi, primary: false, ip: "192.168.1.70", rx: 5_500_000, tx: 380_000)],
                    combine: combine, findings: [], settings: s, speed: speed)
    }

    /// iPhone plugged in and sharing, but macOS keeps the cable idle ("Disable unless needed" is on).
    public static func usbIdle() -> StatusReport {
        let usb = ServiceInfo(id: "usb", name: "iPhone USB", bsd: "en7", kind: .tether, enabled: true, idleUnlessNeeded: true)
        let snap = NetworkSnapshot(services: [usb, ServiceInfo(id: "wifi", name: "Wi-Fi", bsd: "en0", kind: .wifi, enabled: true)],
                                   links: [LinkState(bsd: "en0", serviceID: "wifi", serviceName: "Wi-Fi", kind: .wifi, ipv4: ["192.168.1.70"], router: "192.168.1.1", up: true, primary: true, iphoneHotspot: false),
                                           LinkState(bsd: "en7", serviceID: "usb", serviceName: "iPhone USB", kind: .tether, ipv4: [], router: nil, up: false, primary: false, iphoneHotspot: false)],
                                   primaryBSD: "en0", iphonesOnUSB: ["iPhone"], wifi: WiFiState(bsd: "en0", power: true))
        let findings = Diagnosis.findings(DiagnosisInput(snapshot: snap, settings: Settings(), helperInstalled: true, helperRunning: true,
                                                         combineRunning: false, combineHealthyLinks: 0, engine: "app"))
        var r = base(summary: "Internet via Wi-Fi",
                     links: [link("en0", "Wi-Fi", .wifi, primary: true, ip: "192.168.1.70", rx: 2_100_000, tx: 150_000),
                             LinkReport(bsd: "en7", name: "iPhone USB", kind: .tether, up: false, primary: false, iphoneHotspot: false, ipv4: [], router: nil, rxBps: 0, txBps: 0)],
                     combine: combineOff, findings: findings.filter { $0.id == "usb-idle-unless-needed" })
        r.usb = USBReport(state: "plugged-in-idle", iphones: ["iPhone"], tetherUp: false)
        return r
    }

    public static func wifiFirst() -> StatusReport {
        let f = Finding(id: "wifi-first", severity: .warn, title: "iPhone USB is connected but the Mac is using Wi-Fi",
                        detail: "macOS uses the first connected service in its service order, and Wi-Fi is above iPhone USB. Ply can move iPhone USB above Wi-Fi.",
                        fix: .preferUSB, fixParams: nil, agentPrompt: "")
        return base(summary: "Internet via Wi-Fi",
                    links: [link("en0", "Wi-Fi", .wifi, primary: true, ip: "192.168.1.70", rx: 2_100_000, tx: 150_000),
                            link("en7", "iPhone USB", .tether, primary: false, ip: "172.20.10.2", rx: 0, tx: 0)],
                    combine: combineOff, findings: [f])
    }
}
