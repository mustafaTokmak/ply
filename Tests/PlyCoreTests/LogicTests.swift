import XCTest
@testable import PlyCore
import PlyShared

final class BalancerTests: XCTestCase {
    func testEqualWeightsAlternate() {
        let b = Balancer(split: .connection)
        var links = [BalancerLink(name: "en0", weight: 1, active: 0, healthy: true), BalancerLink(name: "en7", weight: 1, active: 0, healthy: true)]
        var counts: [String: Int] = [:]
        for _ in 0..<10 {
            let pick = b.choose(host: "example.com", links: links)!
            counts[pick, default: 0] += 1
            links = links.map { var l = $0; if l.name == pick { l.active += 1 }; return l }
        }
        XCTAssertEqual(counts["en0"], 5)
        XCTAssertEqual(counts["en7"], 5)
    }

    func testWeightedLinkGetsMore() {
        let b = Balancer(split: .connection)
        var links = [BalancerLink(name: "wifi", weight: 0.25, active: 0, healthy: true), BalancerLink(name: "usb", weight: 1, active: 0, healthy: true)]
        var counts: [String: Int] = [:]
        for _ in 0..<20 {
            let pick = b.choose(host: "cdn.example.com", links: links)!
            counts[pick, default: 0] += 1
            links = links.map { var l = $0; if l.name == pick { l.active += 1 }; return l }
        }
        XCTAssertEqual(counts["usb"], 16)
        XCTAssertEqual(counts["wifi"], 4)
    }

    func testUnhealthySkippedUnlessNothingElse() {
        let b = Balancer(split: .connection)
        let links = [BalancerLink(name: "a", weight: 1, active: 0, healthy: false), BalancerLink(name: "b", weight: 1, active: 9, healthy: true)]
        XCTAssertEqual(b.choose(host: "x.com", links: links), "b")
        XCTAssertEqual(b.choose(host: "x.com", links: links, excluding: ["b"]), "a")
        XCTAssertNil(b.choose(host: "x.com", links: links, excluding: ["a", "b"]))
    }

    func testSiteStickiness() {
        let b = Balancer(split: .site)
        var links = [BalancerLink(name: "a", weight: 1, active: 0, healthy: true), BalancerLink(name: "b", weight: 1, active: 0, healthy: true)]
        let first = b.choose(host: "www.bank.co.uk", links: links)!
        links = links.map { var l = $0; if l.name == first { l.active = 5 }; return l }
        XCTAssertEqual(b.choose(host: "login.bank.co.uk", links: links), first, "same site must stick")
        XCTAssertNotEqual(b.choose(host: "other.com", links: links), first)
        let later = Date().addingTimeInterval(700)
        XCTAssertNotEqual(b.choose(host: "bank.co.uk", links: links, now: later), first, "stickiness expires")
    }

    func testSiteKey() {
        XCTAssertEqual(Balancer.siteKey("a.b.example.com"), "example.com")
        XCTAssertEqual(Balancer.siteKey("www.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(Balancer.siteKey("example.com"), "example.com")
        XCTAssertEqual(Balancer.siteKey("10.0.0.1"), "10.0.0.1")
        XCTAssertEqual(Balancer.siteKey("[2001:db8::1]"), "2001:db8::1")
    }

    func testWeightsFloor() {
        let w = Balancer.weights(peaks: ["a": 1000, "b": 10])
        XCTAssertEqual(w["a"], 1)
        XCTAssertEqual(w["b"], 0.25)
        XCTAssertEqual(Balancer.weights(peaks: ["a": 0, "b": 0]), ["a": 1, "b": 1])
    }
}

final class HandshakeTests: XCTestCase {
    func testSocks5Domain() {
        var h = Handshake()
        XCTAssertEqual(h.feed(Data([0x05, 0x01])), .needMore)
        XCTAssertEqual(h.feed(Data([0x00])), .reply(Data([0x05, 0x00])))
        XCTAssertEqual(h.step(), .needMore)
        let host = Array("example.com".utf8)
        var req: [UInt8] = [0x05, 0x01, 0x00, 0x03, UInt8(host.count)] + host + [0x01, 0xBB]
        req += [0x16, 0x03]
        guard case .connect(let t, let ok, _, let pre) = h.feed(Data(req)) else { return XCTFail("expected connect") }
        XCTAssertEqual(t, ProxyTarget(host: "example.com", port: 443))
        XCTAssertEqual(ok?.first, 0x05)
        XCTAssertEqual(pre, Data([0x16, 0x03]), "early client data is forwarded")
    }

    func testSocks5GreetingAndRequestTogether() {
        var h = Handshake()
        let step = h.feed(Data([0x05, 0x01, 0x00, 0x05, 0x01, 0x00, 0x01, 1, 1, 1, 1, 0x00, 0x50]))
        XCTAssertEqual(step, .reply(Data([0x05, 0x00])))
        guard case .connect(let t, _, _, _) = h.step() else { return XCTFail() }
        XCTAssertEqual(t, ProxyTarget(host: "1.1.1.1", port: 80))
    }

    func testSocks5IPv6AndUnsupported() {
        var h = Handshake()
        _ = h.feed(Data([0x05, 0x01, 0x00]))
        var req: [UInt8] = [0x05, 0x01, 0x00, 0x04, 0x20, 0x01, 0x0d, 0xb8] + [UInt8](repeating: 0, count: 11) + [0x01, 0x01, 0xBB]
        guard case .connect(let t, _, _, _) = h.feed(Data(req)) else { return XCTFail() }
        XCTAssertEqual(t.host, "2001:db8:0:0:0:0:0:1")
        var u = Handshake()
        _ = u.feed(Data([0x05, 0x01, 0x00]))
        req = [0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
        guard case .reject(let d) = u.feed(Data(req)) else { return XCTFail("UDP ASSOCIATE must be rejected") }
        XCTAssertEqual(d?[1], 0x07)
        var noAuth = Handshake()
        XCTAssertEqual(noAuth.feed(Data([0x05, 0x01, 0x02])), .reject(Data([0x05, 0xFF])))
    }

    func testSocks4a() {
        var h = Handshake()
        let req: [UInt8] = [0x04, 0x01, 0x01, 0xBB, 0, 0, 0, 1] + Array("me".utf8) + [0] + Array("example.org".utf8) + [0]
        guard case .connect(let t, let ok, _, _) = h.feed(Data(req)) else { return XCTFail() }
        XCTAssertEqual(t, ProxyTarget(host: "example.org", port: 443))
        XCTAssertEqual(ok?[1], 0x5A)
    }

    func testHTTPConnect() {
        var h = Handshake()
        XCTAssertEqual(h.feed(Data("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n".utf8)), .needMore)
        guard case .connect(let t, let ok, _, let pre) = h.feed(Data("\r\n".utf8)) else { return XCTFail() }
        XCTAssertEqual(t, ProxyTarget(host: "example.com", port: 443))
        XCTAssertTrue(String(decoding: ok ?? Data(), as: UTF8.self).hasPrefix("HTTP/1.1 200"))
        XCTAssertTrue(pre.isEmpty)
        var v6 = Handshake()
        guard case .connect(let t6, _, _, _) = v6.feed(Data("CONNECT [2001:db8::1]:8443 HTTP/1.1\r\n\r\n".utf8)) else { return XCTFail() }
        XCTAssertEqual(t6, ProxyTarget(host: "2001:db8::1", port: 8443))
    }

    func testHTTPAbsoluteFormIsRewritten() {
        var h = Handshake()
        let raw = "GET http://example.com:8080/a/b?q=1 HTTP/1.1\r\nHost: example.com:8080\r\nProxy-Connection: keep-alive\r\nConnection: keep-alive\r\nAccept: */*\r\n\r\nBODY"
        guard case .connect(let t, let ok, _, let pre) = h.feed(Data(raw.utf8)) else { return XCTFail() }
        XCTAssertEqual(t, ProxyTarget(host: "example.com", port: 8080))
        XCTAssertNil(ok)
        let text = String(decoding: pre, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("GET /a/b?q=1 HTTP/1.1\r\n"))
        XCTAssertFalse(text.lowercased().contains("proxy-connection"))
        XCTAssertTrue(text.contains("Connection: close\r\n\r\nBODY"))
        XCTAssertTrue(text.contains("Accept: */*"))
    }

    func testGarbageRejected() {
        var h = Handshake()
        guard case .reject = h.feed(Data("HELLO\r\n\r\n".utf8)) else { return XCTFail() }
        var g = Handshake()
        guard case .reject = g.feed(Data("GET /proxy.pac HTTP/1.1\r\n\r\n".utf8)) else { return XCTFail() }
    }
}

final class SettingsAndPolicyTests: XCTestCase {
    func testDecodeMissingKeysUsesDefaults() throws {
        let s = try JSONCoding.decoder.decode(Settings.self, from: Data(#"{"combineAuto":true}"#.utf8))
        XCTAssertTrue(s.combineAuto)
        XCTAssertTrue(s.preferUSB)
        XCTAssertEqual(s.split, .connection)
    }

    func testMergeValidates() throws {
        let s = Settings()
        XCTAssertEqual(try s.merged(with: ["split": .string("site")]).split, .site)
        XCTAssertThrowsError(try s.merged(with: ["nope": .bool(true)]))
        XCTAssertThrowsError(try s.merged(with: ["preferUSB": .string("yes")]))
        XCTAssertThrowsError(try s.merged(with: ["speedTestMaxMB": .number(1)]))
        XCTAssertThrowsError(try s.merged(with: ["speedTestURL": .string("http://insecure.example")]))
        XCTAssertThrowsError(try s.merged(with: ["tetherInterfaces": .array([.string("rm -rf")])]))
        XCTAssertEqual(try s.merged(with: ["tetherInterfaces": .array([.string("en9")])]).tetherInterfaces, ["en9"])
    }

    func svc(_ id: String, _ kind: LinkKind) -> ServiceInfo { ServiceInfo(id: id, name: id, bsd: nil, kind: kind, enabled: true) }

    func testUSBFirstOrder() {
        // The home-server case: three iPhone USB services below Wi-Fi.
        let s = [svc("tb", .other), svc("wifi", .wifi), svc("usb1", .tether), svc("usb2", .tether), svc("vpn", .other)]
        XCTAssertEqual(ServiceOrder.usbFirst(s), ["tb", "usb1", "usb2", "wifi", "vpn"])
        XCTAssertNil(ServiceOrder.usbFirst(["usb1", "wifi"].map { svc($0, $0 == "wifi" ? .wifi : .tether) }), "already right")
        XCTAssertNil(ServiceOrder.usbFirst([svc("wifi", .wifi), svc("eth", .ethernet)]), "no tether")
        XCTAssertEqual(ServiceOrder.usbFirst([svc("eth", .ethernet), svc("wifi", .wifi), svc("usb", .tether)]), ["eth", "usb", "wifi"], "Ethernet keeps priority")
    }

    func testClassify() {
        XCTAssertEqual(NetworkInspector.classify(interfaceType: "IEEE80211", displayName: "Wi-Fi", serviceName: "Wi-Fi", bsd: "en0", router: "172.20.10.1", extraTether: []), .wifi)
        XCTAssertEqual(NetworkInspector.classify(interfaceType: "Ethernet", displayName: "iPhone USB", serviceName: "iPhone USB", bsd: "en7", router: nil, extraTether: []), .tether)
        XCTAssertEqual(NetworkInspector.classify(interfaceType: "Ethernet", displayName: "USB 10/100/1000 LAN", serviceName: "LAN", bsd: "en5", router: "192.168.1.1", extraTether: []), .ethernet)
        XCTAssertEqual(NetworkInspector.classify(interfaceType: "Ethernet", displayName: "Pixel", serviceName: "Pixel", bsd: "en9", router: "192.168.42.129", extraTether: ["en9"]), .tether)
        XCTAssertEqual(NetworkInspector.classify(interfaceType: "Bridge", displayName: "Thunderbolt Bridge", serviceName: "Thunderbolt Bridge", bsd: "bridge0", router: nil, extraTether: []), .other)
    }

    func link(_ bsd: String, _ kind: LinkKind, up: Bool, primary: Bool = false, hotspot: Bool = false) -> LinkState {
        LinkState(bsd: bsd, serviceID: bsd, serviceName: kind == .tether ? "iPhone USB" : "Wi-Fi", kind: kind, ipv4: up ? ["172.20.10.2"] : [],
                  router: up ? (hotspot ? "172.20.10.1" : "192.168.1.1") : nil, up: up, primary: primary, iphoneHotspot: hotspot)
    }

    func testDiagnosisWifiFirst() {
        let snap = NetworkSnapshot(services: [svc("en0", .wifi), svc("en7", .tether)],
                                   links: [link("en0", .wifi, up: true, primary: true), link("en7", .tether, up: true, hotspot: true)],
                                   primaryBSD: "en0", iphonesOnUSB: ["iPhone"], wifi: WiFiState(bsd: "en0", power: true))
        let f = Diagnosis.findings(DiagnosisInput(snapshot: snap, settings: Settings(), helperInstalled: true, helperRunning: true, combineRunning: false, combineHealthyLinks: 0, engine: "app"))
        let wf = f.first { $0.id == "wifi-first" }
        XCTAssertEqual(wf?.fix, .preferUSB)
        XCTAssertTrue(wf?.agentPrompt.contains("ply prefer-usb") ?? false)
        let noHelper = Diagnosis.findings(DiagnosisInput(snapshot: snap, settings: Settings(), helperInstalled: false, helperRunning: false, combineRunning: false, combineHealthyLinks: 0, engine: "app"))
        XCTAssertEqual(noHelper.first { $0.id == "wifi-first" }?.fix, .installHelper)
    }

    func testDiagnosisHotspotOffAndOK() {
        let plugged = NetworkSnapshot(services: [svc("en0", .wifi), svc("en7", .tether)],
                                      links: [link("en0", .wifi, up: true, primary: true), link("en7", .tether, up: false)],
                                      primaryBSD: "en0", iphonesOnUSB: ["iPhone"], wifi: WiFiState())
        let f = Diagnosis.findings(DiagnosisInput(snapshot: plugged, settings: Settings(), helperInstalled: true, helperRunning: true, combineRunning: false, combineHealthyLinks: 0, engine: "app"))
        XCTAssertEqual(f.first?.id, "hotspot-off")
        XCTAssertTrue(f.first?.detail.contains("Allow Others to Join") ?? false)

        let good = NetworkSnapshot(services: [svc("en7", .tether), svc("en0", .wifi)],
                                   links: [link("en7", .tether, up: true, primary: true, hotspot: true), link("en0", .wifi, up: false)],
                                   primaryBSD: "en7", iphonesOnUSB: ["iPhone"], wifi: WiFiState())
        let g = Diagnosis.findings(DiagnosisInput(snapshot: good, settings: Settings(), helperInstalled: true, helperRunning: true, combineRunning: false, combineHealthyLinks: 0, engine: "app"))
        XCTAssertEqual(g.first?.id, "ok")
        XCTAssertTrue(g.first?.title.contains("iPhone USB") ?? false)
    }

    func testDisableUntilNeededDefaults() {
        // Apple's default when nothing is stored: on for phone tethers, off for everything else.
        XCTAssertTrue(DisableUntilNeeded.effective(stored: nil, isTether: true))
        XCTAssertFalse(DisableUntilNeeded.effective(stored: nil, isTether: false))
        XCTAssertFalse(DisableUntilNeeded.effective(stored: false, isTether: true))
        XCTAssertTrue(DisableUntilNeeded.effective(stored: true, isTether: false))
        XCTAssertEqual(DisableUntilNeeded.path(setID: "S1", bsd: "en7"), "/Sets/S1/Network/Interface/en7")
    }

    func testDiagnosisUSBIdleUnlessNeeded() {
        var idleUSB = svc("en7", .tether)
        idleUSB.idleUnlessNeeded = true
        // iPhone plugged in and sharing, but macOS keeps the cable idle because Wi-Fi works:
        // this must not be reported as "hotspot off".
        let snap = NetworkSnapshot(services: [idleUSB, svc("en0", .wifi)],
                                   links: [link("en0", .wifi, up: true, primary: true), link("en7", .tether, up: false)],
                                   primaryBSD: "en0", iphonesOnUSB: ["iPhone"], wifi: WiFiState())
        let f = Diagnosis.findings(DiagnosisInput(snapshot: snap, settings: Settings(), helperInstalled: true, helperRunning: true, combineRunning: false, combineHealthyLinks: 0, engine: "app"))
        XCTAssertEqual(f.first?.id, "usb-idle-unless-needed")
        XCTAssertEqual(f.first?.severity, .warn)
        XCTAssertEqual(f.first?.fix, .preferUSB)
        XCTAssertFalse(f.contains { $0.id == "hotspot-off" })
        let noHelper = Diagnosis.findings(DiagnosisInput(snapshot: snap, settings: Settings(), helperInstalled: false, helperRunning: false, combineRunning: false, combineHealthyLinks: 0, engine: "app"))
        XCTAssertEqual(noHelper.first?.fix, .installHelper)

        // Cable works now (no other network), but will go idle once Wi-Fi connects.
        let alone = NetworkSnapshot(services: [idleUSB, svc("en0", .wifi)],
                                    links: [link("en7", .tether, up: true, primary: true, hotspot: true), link("en0", .wifi, up: false)],
                                    primaryBSD: "en7", iphonesOnUSB: ["iPhone"], wifi: WiFiState())
        let g = Diagnosis.findings(DiagnosisInput(snapshot: alone, settings: Settings(), helperInstalled: true, helperRunning: true, combineRunning: false, combineHealthyLinks: 0, engine: "app"))
        XCTAssertEqual(g.first { $0.id == "usb-idle-unless-needed" }?.severity, .info)

        // Switched off: no finding.
        let fine = Diagnosis.findings(DiagnosisInput(snapshot: NetworkSnapshot(services: [svc("en7", .tether), svc("en0", .wifi)], links: alone.links, primaryBSD: "en7", iphonesOnUSB: ["iPhone"], wifi: WiFiState()),
                                                     settings: Settings(), helperInstalled: true, helperRunning: true, combineRunning: false, combineHealthyLinks: 0, engine: "app"))
        XCTAssertFalse(fine.contains { $0.id == "usb-idle-unless-needed" })
    }
}

final class ProtocolTests: XCTestCase {
    func testPACURLPolicy() {
        XCTAssertTrue(PACURLPolicy.isAllowed("http://127.0.0.1:7590/proxy.pac"))
        XCTAssertFalse(PACURLPolicy.isAllowed("http://evil.com:7590/proxy.pac"))
        XCTAssertFalse(PACURLPolicy.isAllowed("http://127.0.0.1:80/proxy.pac"))
        XCTAssertFalse(PACURLPolicy.isAllowed("http://127.0.0.1:7590/x/proxy.pac"))
        XCTAssertFalse(PACURLPolicy.isAllowed("http://127.0.0.1:7590@evil.com/proxy.pac"))
    }

    func testPACScript() {
        let pac = PAC.script(proxyPort: 7591)
        XCTAssertTrue(pac.contains("SOCKS5 127.0.0.1:7591; SOCKS 127.0.0.1:7591; DIRECT"))
        XCTAssertTrue(pac.contains("100.64.0.0"), "Tailscale/CGNAT addresses stay direct")
        XCTAssertTrue(pac.contains("isPlainHostName"))
    }

    func testHTTPRequestParse() throws {
        XCTAssertNil(try HTTPRequest.parse(Data("POST /v1/actions/status HTTP/1.1\r\nHost: 127.0.0.1:7590\r\n".utf8)))
        let partial = Data("POST /v1/actions/x HTTP/1.1\r\nContent-Length: 5\r\n\r\nab".utf8)
        XCTAssertNil(try HTTPRequest.parse(partial))
        let full = try HTTPRequest.parse(Data("POST /v1/actions/update_settings?x=1 HTTP/1.1\r\nHost: localhost:7590\r\nContent-Length: 2\r\n\r\n{}".utf8))
        XCTAssertEqual(full?.path, "/v1/actions/update_settings")
        XCTAssertEqual(full?.query, "x=1")
        XCTAssertEqual(full?.headers["host"], "localhost:7590")
        XCTAssertEqual(full?.body, Data("{}".utf8))
        XCTAssertThrowsError(try HTTPRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8)))
    }

    func testRoutes() {
        XCTAssertEqual(APIRoute.resolve(method: "GET", path: "/v1/actions/status"), .action(.status))
        XCTAssertNil(APIRoute.resolve(method: "GET", path: "/v1/actions/combine_start"), "mutating actions need POST")
        XCTAssertEqual(APIRoute.resolve(method: "GET", path: "/proxy.pac"), .pac)
        XCTAssertFalse(APIRoute.pac.needsAuth)
        XCTAssertTrue(APIRoute.action(.status).needsAuth)
        XCTAssertNil(APIRoute.resolve(method: "POST", path: "/v1/actions/rm"))
    }

    func testJSONValueRoundTrip() throws {
        let v = JSONValue.object(["a": .number(3), "b": .array([.bool(true), .null, .string("x")]), "c": .number(1.5)])
        XCTAssertEqual(try JSONValue.parse(Data(v.compact().utf8)), v)
        XCTAssertEqual(v.compact(), #"{"a":3,"b":[true,null,"x"],"c":1.5}"#)
    }

    func testCounterWrap() {
        XCTAssertEqual(CounterSampler.delta(10, 5), 5)
        XCTAssertEqual(CounterSampler.delta(5, UInt64(UInt32.max) - 4), 10)
    }
}
