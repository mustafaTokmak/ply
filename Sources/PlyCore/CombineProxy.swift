import Foundation
import Network

/// Combine mode: a local proxy (SOCKS5, SOCKS4a, HTTP CONNECT, plain HTTP) on
/// 127.0.0.1 that opens each outgoing connection on a chosen interface
/// (Wi-Fi, iPhone USB, Ethernet). Every connection uses one link; many
/// connections at once use all of them.
public final class CombineProxy: @unchecked Sendable {
    public let port: UInt16
    let q = DispatchQueue(label: "app.ply.proxy")
    private var listener: NWListener?
    private let monitor = NWPathMonitor()
    private var interfaces: [String: NWInterface] = [:]
    private var links: [String: LinkRuntime] = [:]
    private var flows: [Int: ProxyFlow] = [:]
    private var nextFlowID = 0
    private var totalFlows = 0
    private let balancer: Balancer
    private var timer: DispatchSourceTimer?
    private var probeCounter = 0

    final class LinkRuntime {
        let bsd: String
        var kind: LinkKind
        var present = true
        var active = 0
        var total = 0
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
        var lastIn: UInt64 = 0
        var lastOut: UInt64 = 0
        var inBps = 0.0
        var outBps = 0.0
        var peak = 0.0
        var health: LinkHealth = .unknown
        var failures = 0
        var consecutiveFailures = 0
        var probing = false

        init(bsd: String, kind: LinkKind) {
            self.bsd = bsd
            self.kind = kind
        }

        var healthy: Bool { present && health != .down && health != .captive && consecutiveFailures < 3 }
    }

    public init(port: UInt16, split: SplitMode) {
        self.port = port
        self.balancer = Balancer(split: split)
    }

    public var split: SplitMode {
        get { q.sync { balancer.split } }
        set { q.async { self.balancer.split = newValue } }
    }

    public func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw PlyError.failed("bad port") }
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        let l: NWListener
        do { l = try NWListener(using: params) } catch {
            throw PlyError.failed("Could not open the Combine proxy on 127.0.0.1:\(port): \(error)")
        }
        let ready = DispatchSemaphore(value: 0)
        var startError: Error?
        l.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let e): startError = e; ready.signal()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            var map: [String: NWInterface] = [:]
            for i in path.availableInterfaces where map[i.name] == nil { map[i.name] = i }
            self.interfaces = map
        }
        monitor.start(queue: q)
        l.start(queue: q)
        if ready.wait(timeout: .now() + 3) == .timedOut || startError != nil {
            l.cancel()
            monitor.cancel()
            throw PlyError.failed("Could not open the Combine proxy on 127.0.0.1:\(port)\(startError.map { ": \($0)" } ?? " (timed out)"). Is another program using the port?")
        }
        listener = l
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    public func stop() {
        q.sync {
            timer?.cancel()
            timer = nil
            listener?.cancel()
            listener = nil
            monitor.cancel()
            for f in flows.values { f.close() }
            flows.removeAll()
        }
    }

    /// Tells the proxy which links currently have internet.
    public func setLinks(_ states: [LinkState]) {
        q.async {
            let names = Set(states.map(\.bsd))
            for s in states {
                if let l = self.links[s.bsd] {
                    if !l.present { l.present = true; l.health = .unknown; l.consecutiveFailures = 0 }
                    l.kind = s.kind
                } else {
                    self.links[s.bsd] = LinkRuntime(bsd: s.bsd, kind: s.kind)
                }
            }
            for (name, l) in self.links where !names.contains(name) { l.present = false }
            self.q.asyncAfter(deadline: .now() + 0.5) {
                for l in self.links.values where l.present && l.health == .unknown { self.probe(l) }
            }
        }
    }

    /// Seeds link weights from a speed test (megabits per second per link).
    public func seed(mbps: [String: Double]) {
        q.async {
            for (name, v) in mbps { self.links[name]?.peak = max(self.links[name]?.peak ?? 0, v * 125_000) }
        }
    }

    public func report() -> (links: [CombineLinkReport], active: Int, total: Int, healthy: Int) {
        q.sync {
            let ls = links.values.filter(\.present).sorted { $0.bsd < $1.bsd }.map {
                CombineLinkReport(bsd: $0.bsd, health: $0.health.rawValue, activeFlows: $0.active, totalFlows: $0.total,
                                  bytesIn: $0.bytesIn, bytesOut: $0.bytesOut, inBps: $0.inBps, outBps: $0.outBps, failures: $0.failures)
            }
            let healthy = links.values.filter { $0.healthy && $0.health == .ok }.count
            return (ls, flows.count, totalFlows, healthy)
        }
    }

    // MARK: internals (all on q)

    private func tick() {
        for l in links.values {
            let din = Double(l.bytesIn - l.lastIn), dout = Double(l.bytesOut - l.lastOut)
            l.lastIn = l.bytesIn
            l.lastOut = l.bytesOut
            l.inBps = din
            l.outBps = dout
            l.peak = max(l.peak * 0.995, din + dout)
        }
        probeCounter += 1
        if probeCounter % 15 == 0 {
            for l in links.values where l.present { probe(l) }
        }
    }

    private func probe(_ link: LinkRuntime) {
        guard !link.probing, let iface = interfaces[link.bsd] else { return }
        link.probing = true
        HealthProbe.run(interface: iface, queue: q) { [weak self, weak link] result in
            guard let self, let link else { return }
            link.probing = false
            link.health = result
            if result == .ok { link.consecutiveFailures = 0 }
            _ = self
        }
    }

    private func accept(_ conn: NWConnection) {
        nextFlowID += 1
        totalFlows += 1
        let flow = ProxyFlow(id: nextFlowID, client: conn, proxy: self)
        flows[flow.id] = flow
        flow.start()
    }

    func pickLink(host: String, excluding: Set<String>) -> (bsd: String, iface: NWInterface)? {
        let present = links.values.filter { $0.present && interfaces[$0.bsd] != nil }
        let weights = Balancer.weights(peaks: Dictionary(present.map { ($0.bsd, $0.peak) }, uniquingKeysWith: { a, _ in a }))
        let candidates = present.map { BalancerLink(name: $0.bsd, weight: weights[$0.bsd] ?? 1, active: $0.active, healthy: $0.healthy) }
        guard let name = balancer.choose(host: host, links: candidates, excluding: excluding), let iface = interfaces[name] else { return nil }
        return (name, iface)
    }

    func connectSucceeded(_ bsd: String) {
        links[bsd]?.consecutiveFailures = 0
    }

    func connectFailed(_ bsd: String) {
        guard let l = links[bsd] else { return }
        l.failures += 1
        l.consecutiveFailures += 1
        if l.consecutiveFailures == 3 { probe(l) }
    }

    func flowStarted(_ bsd: String) {
        links[bsd]?.active += 1
        links[bsd]?.total += 1
    }

    func flowEnded(_ bsd: String) {
        if let l = links[bsd] { l.active = max(0, l.active - 1) }
    }

    func count(_ bsd: String, bytes: Int, upstreamBound: Bool) {
        guard let l = links[bsd] else { return }
        if upstreamBound { l.bytesOut += UInt64(bytes) } else { l.bytesIn += UInt64(bytes) }
    }

    func remove(_ id: Int) {
        flows[id] = nil
    }
}

public enum LinkHealth: String, Codable, Sendable {
    case unknown, ok, captive, down
}

/// One proxied connection: client <-> Ply <-> server on one chosen link.
final class ProxyFlow {
    let id: Int
    let client: NWConnection
    unowned let proxy: CombineProxy
    private var upstream: NWConnection?
    private var handshake = Handshake()
    private var target: ProxyTarget?
    private var successReply: Data?
    private var failureReply: Data?
    private var preamble = Data()
    private var attempted = Set<String>()
    private var link: String?
    private var established = false
    private var closed = false
    private var doneUp = false
    private var doneDown = false

    init(id: Int, client: NWConnection, proxy: CombineProxy) {
        self.id = id
        self.client = client
        self.proxy = proxy
    }

    func start() {
        client.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        client.start(queue: proxy.q)
        readHandshake()
        proxy.q.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, !self.closed, !self.established, self.upstream == nil else { return }
            self.close()
        }
    }

    private func readHandshake() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.handle(self.handshake.feed(data))
            } else if isComplete || error != nil {
                self.close()
            } else {
                self.readHandshake()
            }
        }
    }

    private func handle(_ step: HandshakeStep) {
        switch step {
        case .needMore:
            readHandshake()
        case .reply(let d):
            client.send(content: d, completion: .contentProcessed { [weak self] err in
                guard let self, !self.closed else { return }
                if err != nil { self.close(); return }
                self.handle(self.handshake.step())
            })
        case .reject(let d):
            if let d {
                client.send(content: d, completion: .contentProcessed { [weak self] _ in self?.close() })
            } else {
                close()
            }
        case .connect(let t, let ok, let fail, let pre):
            target = t
            successReply = ok
            failureReply = fail
            preamble = pre
            connectNext()
        }
    }

    private func connectNext() {
        guard let t = target, let pick = proxy.pickLink(host: t.host, excluding: attempted),
              let port = NWEndpoint.Port(rawValue: t.port) else {
            failClient()
            return
        }
        attempted.insert(pick.bsd)
        link = pick.bsd
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 8
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 60
        let params = NWParameters(tls: nil, tcp: tcp)
        params.requiredInterface = pick.iface
        params.preferNoProxies = true
        let up = NWConnection(host: NWEndpoint.Host(t.host), port: port, using: params)
        upstream = up
        let linkName = pick.bsd
        var settled = false
        let giveUp: () -> Void = { [weak self, weak up] in
            guard let self, !self.closed, !settled else { return }
            settled = true
            up?.stateUpdateHandler = nil
            up?.cancel()
            self.upstream = nil
            self.proxy.connectFailed(linkName)
            self.connectNext()
        }
        up.stateUpdateHandler = { [weak self] st in
            guard let self, !self.closed else { return }
            switch st {
            case .ready:
                guard !settled else { return }
                settled = true
                self.proxy.connectSucceeded(linkName)
                self.onEstablished(up)
            case .waiting, .failed:
                if self.established { self.close() } else { giveUp() }
            case .cancelled:
                if self.established { self.close() }
            default:
                break
            }
        }
        up.start(queue: proxy.q)
        proxy.q.asyncAfter(deadline: .now() + 9) { if !settled { giveUp() } }
    }

    private func failClient() {
        if let f = failureReply {
            client.send(content: f, completion: .contentProcessed { [weak self] _ in self?.close() })
        } else {
            close()
        }
    }

    private func onEstablished(_ up: NWConnection) {
        established = true
        guard let link else { close(); return }
        proxy.flowStarted(link)
        if !preamble.isEmpty {
            proxy.count(link, bytes: preamble.count, upstreamBound: true)
            up.send(content: preamble, completion: .contentProcessed { [weak self] err in if err != nil { self?.close() } })
            preamble = Data()
        }
        let startPumps: () -> Void = { [weak self] in
            guard let self, !self.closed else { return }
            self.pump(from: self.client, to: up, upstreamBound: true)
            self.pump(from: up, to: self.client, upstreamBound: false)
        }
        if let ok = successReply {
            client.send(content: ok, completion: .contentProcessed { [weak self] err in
                if err != nil { self?.close() } else { startPumps() }
            })
        } else {
            startPumps()
        }
    }

    private func pump(from: NWConnection, to: NWConnection, upstreamBound: Bool) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                if let link = self.link { self.proxy.count(link, bytes: data.count, upstreamBound: upstreamBound) }
                to.send(content: data, completion: .contentProcessed { [weak self] err in
                    guard let self, !self.closed else { return }
                    if err != nil { self.close(); return }
                    if isComplete { self.finish(to: to, upstreamBound: upstreamBound) } else { self.pump(from: from, to: to, upstreamBound: upstreamBound) }
                })
            } else if isComplete {
                self.finish(to: to, upstreamBound: upstreamBound)
            } else if error != nil {
                self.close()
            } else {
                self.pump(from: from, to: to, upstreamBound: upstreamBound)
            }
        }
    }

    private func finish(to: NWConnection, upstreamBound: Bool) {
        to.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        if upstreamBound { doneUp = true } else { doneDown = true }
        if doneUp && doneDown {
            close()
        } else {
            proxy.q.asyncAfter(deadline: .now() + 60) { [weak self] in self?.close() }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        client.stateUpdateHandler = nil
        client.cancel()
        upstream?.stateUpdateHandler = nil
        upstream?.cancel()
        if established, let link { proxy.flowEnded(link) }
        proxy.remove(id)
    }
}

/// Checks a link really reaches the internet (and is not a captive portal) using
/// Apple's own captive-portal URL, bound to that interface.
enum HealthProbe {
    static func run(interface: NWInterface, queue: DispatchQueue, completion: @escaping (LinkHealth) -> Void) {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 5
        let params = NWParameters(tls: nil, tcp: tcp)
        params.requiredInterface = interface
        params.preferNoProxies = true
        let conn = NWConnection(host: "captive.apple.com", port: 80, using: params)
        var done = false
        var body = Data()
        func finish(_ h: LinkHealth) {
            guard !done else { return }
            done = true
            conn.stateUpdateHandler = nil
            conn.cancel()
            completion(h)
        }
        func read() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, isComplete, error in
                if let data { body.append(data) }
                let text = String(decoding: body, as: UTF8.self)
                if text.contains("<TITLE>Success</TITLE>") || text.contains("<title>Success</title>") { finish(.ok); return }
                if isComplete || error != nil || body.count > 64 * 1024 { finish(body.isEmpty ? .down : .captive); return }
                read()
            }
        }
        conn.stateUpdateHandler = { st in
            switch st {
            case .ready:
                let req = "GET /hotspot-detect.html HTTP/1.0\r\nHost: captive.apple.com\r\nUser-Agent: CaptiveNetworkSupport/1.0 wispr\r\n\r\n"
                conn.send(content: Data(req.utf8), completion: .contentProcessed { _ in read() })
            case .waiting, .failed:
                finish(.down)
            default:
                break
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 6) { finish(body.isEmpty ? .down : .captive) }
    }
}
