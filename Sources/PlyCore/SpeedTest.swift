import Foundation
import Network

public struct SpeedTestLinkResult: Codable, Equatable, Sendable {
    public var bsd: String
    public var name: String
    public var mbps: Double
    public var megabytes: Double
    public var connectMs: Double?
    public var error: String?
}

public struct SpeedTestResult: Codable, Equatable, Sendable {
    public var startedAt: Date
    public var seconds: Int
    public var each: [SpeedTestLinkResult]
    public var combined: [SpeedTestLinkResult]
    public var combinedMbps: Double?
    public var bestSingleMbps: Double?
    /// How much faster all links together were than the best single link.
    public var gainPercent: Double?
    public var megabytesUsed: Double
    public var note: String

    public var headline: String {
        var parts = each.map { "\($0.name) \(Self.fmt($0.mbps))" }
        if let c = combinedMbps { parts.append("both \(Self.fmt(c))") }
        return parts.isEmpty ? "no result" : parts.joined(separator: " · ") + " Mbps"
    }

    static func fmt(_ v: Double) -> String { v >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v) }
}

/// Download speed test bound to each interface (no proxy involved), so it works
/// with or without Combine running.
enum SpeedTester {
    struct LinkTarget {
        let bsd: String
        let name: String
        let iface: NWInterface
    }

    static func interfaces(named names: [String]) async -> [String: NWInterface] {
        await withCheckedContinuation { cont in
            let m = NWPathMonitor()
            let q = DispatchQueue(label: "app.ply.speedtest.monitor")
            final class Flag: @unchecked Sendable { var set = false }
            let resumed = Flag()
            m.pathUpdateHandler = { path in
                guard !resumed.set else { return }
                resumed.set = true
                var map: [String: NWInterface] = [:]
                for i in path.availableInterfaces where names.contains(i.name) && map[i.name] == nil { map[i.name] = i }
                m.cancel()
                cont.resume(returning: map)
            }
            m.start(queue: q)
            q.asyncAfter(deadline: .now() + 2) {
                guard !resumed.set else { return }
                resumed.set = true
                m.cancel()
                cont.resume(returning: [:])
            }
        }
    }

    static func run(links: [LinkState], url: URL, seconds: Int, maxBytesPerLink: Int, mode: String) async -> SpeedTestResult {
        let started = Date()
        let ifaces = await interfaces(named: links.map(\.bsd))
        let targets = links.compactMap { l in ifaces[l.bsd].map { LinkTarget(bsd: l.bsd, name: l.displayName, iface: $0) } }
        var each: [SpeedTestLinkResult] = []
        var combined: [SpeedTestLinkResult] = []
        if mode == "each" || mode == "both" {
            for t in targets {
                each.append(await measure(t, url: url, seconds: Double(seconds), maxBytes: maxBytesPerLink))
            }
        }
        if (mode == "combined" && targets.count >= 1) || (mode == "both" && targets.count >= 2) {
            combined = await withTaskGroup(of: SpeedTestLinkResult.self) { group in
                for t in targets { group.addTask { await measure(t, url: url, seconds: Double(seconds), maxBytes: maxBytesPerLink) } }
                var out: [SpeedTestLinkResult] = []
                for await r in group { out.append(r) }
                return out.sorted { $0.bsd < $1.bsd }
            }
        }
        let best = each.map(\.mbps).max()
        let combinedTotal = combined.isEmpty ? nil : combined.map(\.mbps).reduce(0, +)
        var gain: Double?
        if let b = best, b > 0, let c = combinedTotal { gain = ((c / b) - 1) * 100 }
        let used = (each + combined).map(\.megabytes).reduce(0, +)
        var note = "Each link alone, then all links at the same time; 4 HTTPS downloads per link, bound to the interface."
        if targets.count < 2 { note += " Only \(targets.count) link has internet, so there is nothing to combine." }
        if targets.count < links.count { note += " Skipped links macOS does not offer as usable: \(Set(links.map(\.bsd)).subtracting(targets.map(\.bsd)).sorted().joined(separator: ", "))." }
        return SpeedTestResult(startedAt: started, seconds: seconds, each: each, combined: combined, combinedMbps: combinedTotal,
                               bestSingleMbps: best, gainPercent: gain, megabytesUsed: (used * 10).rounded() / 10, note: note)
    }

    /// Four parallel downloads on one interface for `seconds`, stopping early at `maxBytes`.
    static func measure(_ t: LinkTarget, url: URL, seconds: Double, maxBytes: Int) async -> SpeedTestLinkResult {
        let meter = Meter(maxBytes: maxBytes)
        let streams = 4
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<streams {
                group.addTask { await stream(t.iface, url: url, seconds: seconds, meter: meter) }
            }
        }
        let snap = meter.snapshot()
        let elapsed = max(snap.elapsed, 0.05)
        let mbps = snap.bytes > 0 ? Double(snap.bytes) * 8 / elapsed / 1_000_000 : 0
        return SpeedTestLinkResult(bsd: t.bsd, name: t.name, mbps: (mbps * 10).rounded() / 10,
                                   megabytes: (Double(snap.bytes) / 1_000_000 * 10).rounded() / 10,
                                   connectMs: snap.connectMs.map { ($0 * 10).rounded() / 10 },
                                   error: snap.bytes == 0 ? (snap.error ?? "no data received") : nil)
    }

    final class Meter: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = 0
        private var firstByte: TimeInterval?
        private var lastByte: TimeInterval?
        private var connectMs: Double?
        private var error: String?
        let maxBytes: Int

        init(maxBytes: Int) { self.maxBytes = maxBytes }

        func add(_ n: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            let now = ProcessInfo.processInfo.systemUptime
            if firstByte == nil { firstByte = now }
            lastByte = now
            bytes += n
            return bytes < maxBytes
        }

        func connected(ms: Double) {
            lock.lock(); defer { lock.unlock() }
            if connectMs == nil || ms < connectMs! { connectMs = ms }
        }

        func fail(_ e: String) {
            lock.lock(); defer { lock.unlock() }
            if error == nil { error = e }
        }

        var full: Bool { lock.lock(); defer { lock.unlock() }; return bytes >= maxBytes }

        func snapshot() -> (bytes: Int, elapsed: Double, connectMs: Double?, error: String?) {
            lock.lock(); defer { lock.unlock() }
            let elapsed = (lastByte ?? 0) - (firstByte ?? 0)
            return (bytes, elapsed, connectMs, error)
        }
    }

    /// Repeats downloads on one interface until the time is up or the byte cap is reached.
    static func stream(_ iface: NWInterface, url: URL, seconds: Double, meter: Meter) async {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        var attempts = 0
        while ProcessInfo.processInfo.systemUptime < deadline - 0.2, !meter.full, attempts < 50 {
            attempts += 1
            let ok = await download(iface, url: url, seconds: deadline - ProcessInfo.processInfo.systemUptime, meter: meter)
            if !ok { break }
        }
    }

    /// One HTTP GET. Returns false on an error (stop retrying).
    static func download(_ iface: NWInterface, url: URL, seconds: Double, meter: Meter) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            guard let host = url.host else { cont.resume(returning: false); return }
            let q = DispatchQueue(label: "app.ply.speedtest")
            let tcp = NWProtocolTCP.Options()
            tcp.connectionTimeout = 6
            let params = NWParameters(tls: url.scheme == "https" ? NWProtocolTLS.Options() : nil, tcp: tcp)
            params.requiredInterface = iface
            params.preferNoProxies = true
            let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? (url.scheme == "https" ? 443 : 80)))!
            let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: params)
            let start = ProcessInfo.processInfo.systemUptime
            final class State: @unchecked Sendable { var done = false; var sawStatus = false; var failed = false }
            let st = State()
            func finish() {
                guard !st.done else { return }
                st.done = true
                conn.stateUpdateHandler = nil
                conn.cancel()
                cont.resume(returning: !st.failed)
            }
            func read() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        if !st.sawStatus {
                            st.sawStatus = true
                            let head = String(decoding: data.prefix(16), as: UTF8.self)
                            if !head.hasPrefix("HTTP/1.1 200") && !head.hasPrefix("HTTP/1.0 200") {
                                meter.fail("server answered \(head.trimmingCharacters(in: .whitespacesAndNewlines))")
                                st.failed = true
                                finish()
                                return
                            }
                        }
                        if !meter.add(data.count) { finish(); return }
                    }
                    if isComplete || error != nil { finish(); return }
                    read()
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    meter.connected(ms: (ProcessInfo.processInfo.systemUptime - start) * 1000)
                    var path = url.path.isEmpty ? "/" : url.path
                    if let q = url.query { path += "?" + q }
                    let req = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nUser-Agent: Ply/0.1 speedtest\r\nAccept: */*\r\nConnection: close\r\n\r\n"
                    conn.send(content: Data(req.utf8), completion: .contentProcessed { _ in read() })
                case .waiting(let e), .failed(let e):
                    meter.fail("\(e)")
                    st.failed = true
                    finish()
                default:
                    break
                }
            }
            conn.start(queue: q)
            q.asyncAfter(deadline: .now() + max(seconds, 0.1)) { finish() }
        }
    }
}
