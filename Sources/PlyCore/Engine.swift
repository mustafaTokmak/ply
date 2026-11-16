import Foundation
import SystemConfiguration
import PlyShared

public protocol LaunchAtLoginControlling: AnyObject {
    var isEnabled: Bool { get }
    func set(_ on: Bool) throws
}

/// The one place where Ply decides and acts. The menu bar app, `ply daemon`,
/// the HTTP API, the CLI and the MCP server all call `perform(_:_:)`.
public final class Engine: @unchecked Sendable {
    public enum Mode: String, Sendable { case app, daemon, passive }

    public let mode: Mode
    let q = DispatchQueue(label: "app.ply.engine")
    private(set) var settings: Settings
    let helper = HelperClient()
    let sampler = CounterSampler()
    var proxy: CombineProxy?
    var combineAutoStarted = false
    var systemProxyActive = false
    var combineWarning: String?
    var wifiTurnedOffByPly = false
    var lastOrderFix = Date.distantPast
    var disassociations: [Date] = []
    var snapshot = NetworkSnapshot.empty
    var lastSpeedTest: SpeedTestResult?
    var speedTestRunning = false
    var events: [EngineEvent] = []
    var store: SCDynamicStore?
    var ticker: DispatchSourceTimer?
    var tickCount = 0
    var evaluateScheduled = false
    var helperVersionCache: (version: String?, at: Date) = (nil, .distantPast)

    public var onChange: ((StatusReport) -> Void)?
    public var onQuit: (() -> Void)?
    public var onShowWindow: (() -> Void)?
    public weak var launchAtLogin: LaunchAtLoginControlling?

    public init(mode: Mode) {
        self.mode = mode
        self.settings = SettingsStore.load()
    }

    // MARK: lifecycle

    public func start() {
        guard mode != .passive else { return }
        q.async {
            if self.helper.isInstalled, let n = try? self.helper.restoreProxies(), n > 0 {
                self.record("Restored proxy settings left over from an earlier run")
            }
            self.startMonitoring()
            self.evaluate()
        }
    }

    /// Stops Combine and puts back anything Ply changed. Blocks until done.
    public func stop() {
        q.sync {
            self.stopCombine()
            if self.wifiTurnedOffByPly { try? WiFiControl.setPower(true); self.wifiTurnedOffByPly = false }
            self.ticker?.cancel()
            self.ticker = nil
            if let store = self.store { SCDynamicStoreSetDispatchQueue(store, nil) }
            self.store = nil
        }
    }

    private func startMonitoring() {
        var ctx = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            Unmanaged<Engine>.fromOpaque(info).takeUnretainedValue().scheduleEvaluate()
        }
        if let s = SCDynamicStoreCreate(nil, "app.ply.engine" as CFString, callback, &ctx) {
            let patterns = ["State:/Network/Global/IPv4", "State:/Network/Interface/.*/IPv4", "State:/Network/Service/.*/IPv4",
                            "State:/Network/Interface/.*/Link", "Setup:/Network/Global/IPv4", "Setup:/Network/Service/.*"]
            SCDynamicStoreSetNotificationKeys(s, nil, patterns as CFArray)
            SCDynamicStoreSetDispatchQueue(s, q)
            store = s
        }
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        ticker = t
    }

    private func tick() {
        tickCount += 1
        sampler.sample()
        if tickCount % 4 == 0 {
            // USB plug/unplug of an iPhone without hotspot does not change network state; poll it.
            let iphones = USBDevices.connectedIOSDevices()
            if iphones != snapshot.iphonesOnUSB { evaluate(); return }
        }
        publish()
    }

    func scheduleEvaluate() {
        guard !evaluateScheduled else { return }
        evaluateScheduled = true
        q.asyncAfter(deadline: .now() + 0.4) {
            self.evaluateScheduled = false
            self.evaluate()
        }
    }

    func evaluate() {
        snapshot = NetworkInspector.snapshot(settings: settings)
        guard mode != .passive else { return }
        if settings.preferUSB { _ = try? applyUSBFirst(force: false) }
        applyWiFiRules()
        applyCombineAuto()
        proxy?.setLinks(snapshot.combineCandidates)
        publish()
    }

    func publish() {
        guard let cb = onChange else { return }
        cb(buildReport())
    }

    func record(_ message: String) {
        events.append(EngineEvent(at: Date(), message: message))
        if events.count > 30 { events.removeFirst(events.count - 30) }
        Log.info(message)
    }

    // MARK: policies

    struct OrderChange: Encodable {
        var changed: Bool
        var message: String
        var order: [String]
    }

    /// Tether services macOS keeps idle while another network works ("Disable unless needed" is on).
    var idleTetherServiceIDs: [String] {
        snapshot.services.filter { $0.kind == .tether && $0.enabled && $0.idleUnlessNeeded }.map(\.id)
    }

    /// Turns off "Disable unless needed" for iPhone USB through the helper. Returns true if it changed anything.
    @discardableResult
    func keepTetherActive() throws -> Bool {
        let ids = idleTetherServiceIDs
        guard !ids.isEmpty, helper.isInstalled else { return false }
        do {
            try helper.keepActive(ids)
        } catch {
            record("Could not keep iPhone USB active: \(error)")
            throw error
        }
        record("Turned off \"Disable unless needed\" for iPhone USB so it stays active next to Wi-Fi")
        snapshot = NetworkInspector.snapshot(settings: settings)
        return true
    }

    func applyUSBFirst(force: Bool) throws -> OrderChange {
        let names = { (ids: [String]) in ids.compactMap { id in self.snapshot.services.first { $0.id == id }?.name } }
        let desired = ServiceOrder.usbFirst(snapshot.services)
        let idle = idleTetherServiceIDs
        guard desired != nil || !idle.isEmpty else {
            let hasTether = snapshot.services.contains { $0.kind == .tether }
            return OrderChange(changed: false, message: hasTether ? "iPhone USB is already above Wi-Fi and stays active." : "macOS has no iPhone USB service yet. Plug in the iPhone and turn on Personal Hotspot first.",
                               order: names(snapshot.services.map(\.id)))
        }
        if !force && Date().timeIntervalSince(lastOrderFix) < 15 {
            return OrderChange(changed: false, message: "Waiting before trying again.", order: names(snapshot.services.map(\.id)))
        }
        guard helper.isInstalled else {
            if force { throw PlyError.needsHelper("Putting iPhone USB first changes macOS network settings, which needs the Ply helper. Install it with `ply helper install`.") }
            return OrderChange(changed: false, message: "Helper not installed.", order: names(snapshot.services.map(\.id)))
        }
        lastOrderFix = Date()
        var done: [String] = []
        if !idle.isEmpty {
            try keepTetherActive()
            done.append("stays active while Wi-Fi is connected (\"Disable unless needed\" is off)")
        }
        if let desired = ServiceOrder.usbFirst(snapshot.services) {
            do {
                try helper.setOrder(desired)
            } catch {
                record("Could not move iPhone USB above Wi-Fi: \(error)")
                throw error
            }
            record("Moved iPhone USB above Wi-Fi in the service order")
            snapshot = NetworkInspector.snapshot(settings: settings)
            done.insert("is now above Wi-Fi", at: 0)
        }
        return OrderChange(changed: true, message: "iPhone USB " + done.joined(separator: " and ") + ".", order: names(snapshot.services.map(\.id)))
    }

    func applyWiFiRules() {
        let tetherUp = !snapshot.tetherUp.isEmpty
        let power = snapshot.wifi.power ?? false
        let combining = proxy != nil
        if settings.wifiOffWhenUSB && tetherUp && power && !combining {
            do {
                try WiFiControl.setPower(false)
                wifiTurnedOffByPly = true
                record("Turned Wi-Fi off because iPhone USB is connected")
            } catch {
                record("Could not turn Wi-Fi off: \(error)")
            }
        } else if wifiTurnedOffByPly && !power && (!tetherUp || !settings.wifiOffWhenUSB || combining) {
            try? WiFiControl.setPower(true)
            wifiTurnedOffByPly = false
            record("Turned Wi-Fi back on")
        }
        if settings.leaveIPhoneWiFiWhenUSB, tetherUp, !combining, let w = snapshot.wifiLink, w.up, w.iphoneHotspot {
            disassociations = disassociations.filter { $0 > Date().addingTimeInterval(-120) }
            if disassociations.count < 3 {
                try? WiFiControl.disassociate()
                disassociations.append(Date())
                record("Left the iPhone's Wi-Fi hotspot because the USB cable already gives internet")
            }
        }
    }

    func applyCombineAuto() {
        let candidates = snapshot.combineCandidates
        let ready = candidates.count >= 2 && candidates.contains { $0.kind == .tether }
        if settings.combineAuto && proxy == nil && ready {
            do {
                _ = try startCombine(auto: true, systemProxy: nil)
                record("Started Combine automatically (\(candidates.map(\.displayName).joined(separator: " + ")))")
            } catch {
                record("Could not start Combine: \(error)")
            }
        } else if combineAutoStarted && (!ready || !settings.combineAuto) {
            stopCombine()
            record("Stopped Combine (fewer than two links)")
        }
    }

    // MARK: combine

    var proxyServiceIDs: [String] {
        snapshot.services.filter { $0.enabled && [.wifi, .tether, .ethernet].contains($0.kind) }.map(\.id)
    }

    func startCombine(auto: Bool, systemProxy: Bool?) throws -> CombineReport {
        guard mode != .passive else { throw PlyError.unavailable("Combine needs a running Ply engine.") }
        if proxy == nil {
            let p = CombineProxy(port: PlyInfo.proxyPort, split: settings.split)
            try p.start()
            proxy = p
            combineAutoStarted = auto
            if let s = lastSpeedTest {
                p.seed(mbps: Dictionary(s.each.map { ($0.bsd, $0.mbps) }, uniquingKeysWith: { a, _ in a }))
            }
        }
        proxy?.split = settings.split
        combineWarning = nil
        // Combine needs iPhone USB up next to Wi-Fi, which macOS prevents while "Disable unless needed" is on.
        if !idleTetherServiceIDs.isEmpty {
            if helper.isInstalled {
                do { try keepTetherActive() } catch { combineWarning = "Could not keep iPhone USB active next to Wi-Fi: \(error)" }
            } else {
                combineWarning = "macOS keeps iPhone USB idle while Wi-Fi works (\"Disable unless needed\"). Install the helper, or turn that off in System Settings > Network > iPhone USB > Details."
            }
        }
        proxy?.setLinks(snapshot.combineCandidates)
        if systemProxy ?? settings.systemProxy {
            if helper.isInstalled {
                do {
                    try helper.setPAC(proxyServiceIDs, url: PlyInfo.pacURL)
                    systemProxyActive = true
                } catch {
                    combineWarning = (combineWarning.map { $0 + " " } ?? "") + "Combine is running, but macOS proxy settings could not be changed: \(error)"
                }
            } else {
                combineWarning = (combineWarning.map { $0 + " " } ?? "") + "Combine is running on 127.0.0.1:\(PlyInfo.proxyPort), but apps will not use it until the helper is installed (or you set SOCKS proxy 127.0.0.1:\(PlyInfo.proxyPort) yourself)."
            }
        } else if systemProxyActive {
            _ = try? helper.restoreProxies()
            systemProxyActive = false
        }
        if snapshot.combineCandidates.count < 2 {
            combineWarning = (combineWarning.map { $0 + " " } ?? "") + "Only \(snapshot.combineCandidates.count) link has internet right now; Combine will use more as they connect."
        }
        return combineReport()
    }

    func stopCombine() {
        if systemProxyActive {
            do {
                try helper.restoreProxies()
            } catch {
                record("Could not restore proxy settings: \(error)")
            }
            systemProxyActive = false
        }
        proxy?.stop()
        proxy = nil
        combineAutoStarted = false
        combineWarning = nil
    }

    func combineReport() -> CombineReport {
        let r = proxy?.report()
        return CombineReport(running: proxy != nil, autoStarted: combineAutoStarted, port: PlyInfo.proxyPort, split: settings.split,
                             systemProxy: systemProxyActive, activeFlows: r?.active ?? 0, totalFlows: r?.total ?? 0,
                             healthyLinks: r?.healthy ?? 0, links: r?.links ?? [], warning: combineWarning)
    }

    // MARK: report

    func helperReport() -> HelperReport {
        let installed = helper.isInstalled
        if Date().timeIntervalSince(helperVersionCache.at) > 20 || (installed && helperVersionCache.version == nil && Date().timeIntervalSince(helperVersionCache.at) > 3) {
            helperVersionCache = (helper.version(), Date())
        }
        let v = installed ? helperVersionCache.version : nil
        return HelperReport(installed: installed, running: v != nil, version: v, needsUpdate: v != nil && v != PlyInfo.version)
    }

    func buildReport() -> StatusReport {
        let s = snapshot
        let combine = combineReport()
        let helperR = helperReport()
        var links: [LinkReport] = []
        for l in s.links {
            let relevant: Bool
            switch l.kind {
            case .wifi: relevant = true
            case .tether: relevant = l.up || (s.tetherUp.isEmpty && !links.contains { $0.kind == .tether })
            case .ethernet: relevant = l.up
            case .other: relevant = false
            }
            guard relevant else { continue }
            let rate = sampler.rates[l.bsd]
            links.append(LinkReport(bsd: l.bsd, name: l.displayName, kind: l.kind, up: l.up, primary: l.primary, iphoneHotspot: l.iphoneHotspot,
                                    ipv4: l.ipv4, router: l.router, rxBps: rate?.rx ?? 0, txBps: rate?.tx ?? 0))
        }
        let idleTether = s.services.contains { $0.kind == .tether && $0.enabled && $0.idleUnlessNeeded }
        let usbState = !s.tetherUp.isEmpty ? "active"
            : s.iphonesOnUSB.isEmpty ? "not-connected"
            : (idleTether && s.primary != nil) ? "plugged-in-idle" : "plugged-in-no-hotspot"
        let w = s.wifiLink
        let findings = Diagnosis.findings(DiagnosisInput(snapshot: s, settings: settings, helperInstalled: helperR.installed, helperRunning: helperR.running,
                                                         combineRunning: combine.running, combineHealthyLinks: combine.healthyLinks, engine: mode.rawValue))
        let summary: String
        if combine.running && combine.healthyLinks >= 2 {
            summary = "Combining " + s.combineCandidates.map(\.displayName).joined(separator: " + ")
        } else if let p = s.primary {
            summary = "Internet via \(p.displayName)"
        } else {
            summary = "No internet connection"
        }
        return StatusReport(app: PlyInfo.name, version: PlyInfo.version, engine: mode.rawValue, summary: summary, primary: s.primary?.bsd,
                            links: links, usb: USBReport(state: usbState, iphones: s.iphonesOnUSB, tetherUp: !s.tetherUp.isEmpty),
                            wifi: WiFiReport(bsd: s.wifi.bsd, power: s.wifi.power, ssid: s.wifi.ssid, up: w?.up ?? false, onIPhoneHotspot: w?.iphoneHotspot ?? false),
                            serviceOrder: s.services, combine: combine, helper: helperR, settings: settings,
                            launchAtLogin: launchAtLogin?.isEnabled, findings: findings, events: events.reversed(),
                            lastSpeedTest: lastSpeedTest, updatedAt: Date())
    }

    // MARK: actions

    func onQueue<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            q.async { cont.resume(with: Result { try body() }) }
        }
    }

    /// Runs one action. This is the only entry point for the UI, API, CLI and MCP.
    public func perform(_ id: ActionID, _ params: Params = [:]) async throws -> JSONValue {
        try Registry.validate(id, params)
        if mode == .passive && Registry.spec(id).host != .anywhere {
            throw PlyError.unavailable("\(id.rawValue) needs a running Ply engine (the menu bar app or `ply daemon`).")
        }
        do {
            return try await run(id, params)
        } catch {
            throw PlyError.wrap(error)
        }
    }

    private func run(_ id: ActionID, _ params: Params) async throws -> JSONValue {
        switch id {
        case .status:
            return try JSONValue(encoding: try await onQueue { self.refreshIfPassive(); return self.buildReport() })

        case .diagnose:
            let r = try await onQueue { () -> StatusReport in self.refreshIfPassive(); return self.buildReport() }
            return .object(["summary": .string(r.summary), "findings": try JSONValue(encoding: r.findings), "engine": .string(r.engine)])

        case .agentPrompt:
            let r = try await onQueue { () -> StatusReport in self.refreshIfPassive(); return self.buildReport() }
            return .object(["prompt": .string(AgentPrompt.make(r))])

        case .preferUSB:
            return try JSONValue(encoding: try await onQueue { self.refreshIfPassive(); return try self.applyUSBFirst(force: true) })

        case .combineStart:
            return try JSONValue(encoding: try await onQueue { () -> CombineReport in
                if let split = params["split"]?.stringValue.flatMap(SplitMode.init(rawValue:)), split != self.settings.split {
                    self.settings.split = split
                    try? SettingsStore.save(self.settings)
                }
                let r = try self.startCombine(auto: false, systemProxy: params["systemProxy"]?.boolValue)
                self.record("Started Combine")
                self.publish()
                return r
            })

        case .combineStop:
            return try JSONValue(encoding: try await onQueue { () -> CombineReport in
                if self.mode == .passive {
                    // No engine running: nothing to stop, but make sure no stale proxy setting is left behind.
                    if self.helper.isInstalled { _ = try? self.helper.restoreProxies() }
                } else {
                    let wasRunning = self.proxy != nil
                    self.stopCombine()
                    if wasRunning { self.record("Stopped Combine") }
                    self.publish()
                }
                return self.combineReport()
            })

        case .speedTest:
            let seconds = min(15, max(2, params["seconds"]?.intValue ?? 5))
            let testMode = params["mode"]?.stringValue ?? "both"
            let (links, url, maxBytes) = try await onQueue { () -> ([LinkState], URL, Int) in
                guard !self.speedTestRunning else { throw PlyError.unavailable("A speed test is already running.") }
                self.refreshIfPassive()
                self.speedTestRunning = true
                guard let url = URL(string: self.settings.speedTestURL) else { throw PlyError.badRequest("Bad speedTestURL") }
                return (self.snapshot.combineCandidates, url, self.settings.speedTestMaxMB * 1_000_000)
            }
            guard !links.isEmpty else {
                q.async { self.speedTestRunning = false }
                throw PlyError.unavailable("No link has internet to test.")
            }
            let result = await SpeedTester.run(links: links, url: url, seconds: seconds, maxBytesPerLink: maxBytes, mode: testMode)
            try await onQueue {
                self.speedTestRunning = false
                self.lastSpeedTest = result
                self.proxy?.seed(mbps: Dictionary(result.each.map { ($0.bsd, $0.mbps) }, uniquingKeysWith: { a, _ in a }))
                self.record("Speed test: \(result.headline)")
                self.publish()
            }
            return try JSONValue(encoding: result)

        case .setWiFiPower:
            let on = params["on"]?.boolValue ?? true
            try await onQueue {
                try WiFiControl.setPower(on)
                if on { self.wifiTurnedOffByPly = false }
                self.record("Wi-Fi turned \(on ? "on" : "off")")
            }
            return .object(["ok": .bool(true), "wifiPower": .bool(on)])

        case .disconnectWiFi:
            try await onQueue {
                try WiFiControl.disassociate()
                self.record("Left the current Wi-Fi network")
            }
            return .object(["ok": .bool(true)])

        case .getSettings:
            return try JSONValue(encoding: try await onQueue { self.settings })

        case .updateSettings:
            return try JSONValue(encoding: try await onQueue { () -> Settings in
                let next = try self.settings.merged(with: params)
                try SettingsStore.save(next)
                let splitChanged = next.split != self.settings.split
                self.settings = next
                if splitChanged { self.proxy?.split = next.split }
                if self.mode != .passive {
                    self.record("Settings changed: \(params.keys.sorted().joined(separator: ", "))")
                    self.evaluate()
                }
                return next
            })

        case .repairTether:
            let services = try await onQueue { () -> [ServiceInfo] in
                self.refreshIfPassive()
                guard self.helper.isInstalled else { throw PlyError.needsHelper("Repair needs the Ply helper. Install it with `ply helper install`.") }
                return self.snapshot.services.filter { $0.kind == .tether }
            }
            guard !services.isEmpty else { throw PlyError.unavailable("macOS has no iPhone USB service to repair. Plug in the iPhone and turn on Personal Hotspot.") }
            for svc in services {
                try helper.setEnabled(svc.id, false)
                try await Task.sleep(nanoseconds: 1_200_000_000)
                try helper.setEnabled(svc.id, true)
            }
            try await Task.sleep(nanoseconds: 3_000_000_000)
            return try await onQueue { () -> JSONValue in
                self.record("Restarted the iPhone USB service")
                self.evaluate()
                return .object(["repaired": .array(services.map { .string($0.name) }), "tetherUp": .bool(!self.snapshot.tetherUp.isEmpty)])
            }

        case .restoreProxies:
            return try await onQueue { () -> JSONValue in
                guard self.helper.isInstalled else { return .object(["restored": .number(0), "note": .string("Helper not installed, so Ply never changed proxy settings.")]) }
                if self.proxy != nil { self.stopCombine() }
                let n = try self.helper.restoreProxies()
                self.systemProxyActive = false
                self.publish()
                return .object(["restored": .number(Double(n))])
            }

        case .installHelper:
            let r = try HelperInstaller.install()
            try await onQueue {
                self.helperVersionCache = (nil, .distantPast)
                self.record("Installed the helper")
                self.evaluate()
            }
            return .object(r)

        case .uninstallHelper:
            try await onQueue { self.stopCombine() }
            let r = try HelperInstaller.uninstall()
            try await onQueue {
                self.helperVersionCache = (nil, .distantPast)
                self.record("Removed the helper")
                self.publish()
            }
            return .object(r)

        case .setLaunchAtLogin:
            guard let c = launchAtLogin else { throw PlyError.unavailable("Open at login is set by the Ply app. Open Ply.app first.") }
            let on = params["on"]?.boolValue ?? true
            try await MainActor.run { try c.set(on) }
            return .object(["launchAtLogin": .bool(c.isEnabled)])

        case .showWindow:
            guard let show = onShowWindow else { throw PlyError.unavailable("The window belongs to the Ply app. Open Ply.app first.") }
            DispatchQueue.main.async { show() }
            return .object(["shown": .bool(true)])

        case .about:
            return .object([
                "name": .string(PlyInfo.name), "version": .string(PlyInfo.version), "license": .string("MIT"),
                "source": .string(PlyInfo.repoURL), "docs": .string(PlyInfo.repoURL + "#readme"),
                "llms": .string(PlyInfo.repoURL + "/blob/main/docs/llms.txt"),
                "api": .string("http://127.0.0.1:\(PlyInfo.apiPort)"), "mcp": .string("ply mcp"),
            ])

        case .quit:
            if mode == .passive { return .object(["stopped": .bool(false), "note": .string("No Ply engine was running.")]) }
            q.asyncAfter(deadline: .now() + 0.3) {
                if let quit = self.onQuit {
                    DispatchQueue.main.async { quit() }
                } else {
                    self.stopCombine()
                    exit(0)
                }
            }
            return .object(["stopped": .bool(true), "engine": .string(mode.rawValue)])
        }
    }

    private func refreshIfPassive() {
        if mode == .passive || snapshot == .empty { snapshot = NetworkInspector.snapshot(settings: settings) }
    }
}
