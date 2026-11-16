import Foundation

public struct ProxyTarget: Equatable, Sendable {
    public var host: String
    public var port: UInt16
}

public enum HandshakeStep: Equatable {
    /// Wait for more bytes from the client.
    case needMore
    /// Send these bytes to the client, then call `step()` again.
    case reply(Data)
    /// Open a connection to `target`. On success send `successReply` (if any) to the client
    /// and `upstreamPreamble` to the server; on failure send `failureReply` and close.
    case connect(target: ProxyTarget, successReply: Data?, failureReply: Data?, upstreamPreamble: Data)
    /// Send these bytes (if any) and close.
    case reject(Data?)
}

/// Incremental parser for the first bytes of a proxy connection.
/// One port speaks SOCKS5, SOCKS4/4a, HTTP CONNECT and plain HTTP proxy requests.
public struct Handshake {
    enum Stage { case start, socks5Request }
    var stage: Stage = .start
    public private(set) var buffer = Data()
    static let maxHeader = 16 * 1024

    public init() {}

    public mutating func feed(_ data: Data) -> HandshakeStep {
        buffer.append(data)
        return step()
    }

    public mutating func step() -> HandshakeStep {
        guard let first = buffer.first else { return .needMore }
        switch stage {
        case .start:
            if first == 0x05 { return socks5Greeting() }
            if first == 0x04 { return socks4() }
            return http()
        case .socks5Request:
            return socks5Request()
        }
    }

    // MARK: SOCKS5 (RFC 1928), no authentication

    static let socks5OK = Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
    static func socks5Fail(_ code: UInt8) -> Data { Data([0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0]) }

    mutating func socks5Greeting() -> HandshakeStep {
        let b = [UInt8](buffer)
        guard b.count >= 2 else { return .needMore }
        let n = Int(b[1])
        guard b.count >= 2 + n else { return .needMore }
        let methods = b[2..<(2 + n)]
        buffer = Data(b[(2 + n)...])
        guard methods.contains(0x00) else { return .reject(Data([0x05, 0xFF])) }
        stage = .socks5Request
        return .reply(Data([0x05, 0x00]))
    }

    mutating func socks5Request() -> HandshakeStep {
        let b = [UInt8](buffer)
        guard b.count >= 4 else { return .needMore }
        guard b[0] == 0x05 else { return .reject(nil) }
        guard b[1] == 0x01 else { return .reject(Self.socks5Fail(0x07)) } // only CONNECT
        var host: String
        var idx: Int
        switch b[3] {
        case 0x01:
            guard b.count >= 10 else { return .needMore }
            host = b[4..<8].map(String.init).joined(separator: ".")
            idx = 8
        case 0x03:
            guard b.count >= 5 else { return .needMore }
            let len = Int(b[4])
            guard b.count >= 5 + len + 2 else { return .needMore }
            host = String(decoding: b[5..<(5 + len)], as: UTF8.self)
            idx = 5 + len
        case 0x04:
            guard b.count >= 22 else { return .needMore }
            var groups: [String] = []
            for i in stride(from: 4, to: 20, by: 2) { groups.append(String(UInt16(b[i]) << 8 | UInt16(b[i + 1]), radix: 16)) }
            host = groups.joined(separator: ":")
            idx = 20
        default:
            return .reject(Self.socks5Fail(0x08))
        }
        let port = UInt16(b[idx]) << 8 | UInt16(b[idx + 1])
        let rest = Data(b[(idx + 2)...])
        buffer = Data()
        guard !host.isEmpty, port != 0 else { return .reject(Self.socks5Fail(0x01)) }
        return .connect(target: ProxyTarget(host: host, port: port), successReply: Self.socks5OK,
                        failureReply: Self.socks5Fail(0x04), upstreamPreamble: rest)
    }

    // MARK: SOCKS4 / 4a

    mutating func socks4() -> HandshakeStep {
        let b = [UInt8](buffer)
        guard b.count >= 9 else { return .needMore }
        let fail = Data([0x00, 0x5B, 0, 0, 0, 0, 0, 0])
        guard b[1] == 0x01 else { return .reject(fail) }
        let port = UInt16(b[2]) << 8 | UInt16(b[3])
        guard let userEnd = b[8...].firstIndex(of: 0) else { return b.count > 512 ? .reject(fail) : .needMore }
        var host = b[4..<8].map(String.init).joined(separator: ".")
        var end = userEnd
        if b[4] == 0, b[5] == 0, b[6] == 0, b[7] != 0 {
            guard let hostEnd = b[(userEnd + 1)...].firstIndex(of: 0) else { return b.count > 512 ? .reject(fail) : .needMore }
            host = String(decoding: b[(userEnd + 1)..<hostEnd], as: UTF8.self)
            end = hostEnd
        }
        let rest = Data(b[(end + 1)...])
        buffer = Data()
        return .connect(target: ProxyTarget(host: host, port: port), successReply: Data([0x00, 0x5A, 0, 0, 0, 0, 0, 0]),
                        failureReply: fail, upstreamPreamble: rest)
    }

    // MARK: HTTP CONNECT and absolute-form requests

    static let http502 = Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    static let http400 = Data("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)

    mutating func http() -> HandshakeStep {
        guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > Self.maxHeader ? .reject(Self.http400) : .needMore
        }
        let head = String(decoding: buffer[buffer.startIndex..<headEnd.lowerBound], as: UTF8.self)
        let rest = Data(buffer[headEnd.upperBound...])
        buffer = Data()
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3 else { return .reject(Self.http400) }
        let method = parts[0].uppercased(), target = parts[1], version = parts[2]

        if method == "CONNECT" {
            guard let t = Self.parseAuthority(target, defaultPort: 443) else { return .reject(Self.http400) }
            return .connect(target: t, successReply: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8),
                            failureReply: Self.http502, upstreamPreamble: rest)
        }
        guard target.lowercased().hasPrefix("http://") else { return .reject(Self.http400) }
        let afterScheme = target.dropFirst("http://".count)
        let slash = afterScheme.firstIndex(where: { $0 == "/" || $0 == "?" }) ?? afterScheme.endIndex
        let authority = String(afterScheme[..<slash])
        var path = String(afterScheme[slash...])
        if path.isEmpty { path = "/" } else if path.hasPrefix("?") { path = "/" + path }
        guard let t = Self.parseAuthority(authority, defaultPort: 80) else { return .reject(Self.http400) }
        let kept = lines.filter { line in
            let name = line.split(separator: ":", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            return !["proxy-connection", "proxy-authorization", "connection", "keep-alive"].contains(name)
        }
        let newHead = (["\(method) \(path) \(version)"] + kept + ["Connection: close", "", ""]).joined(separator: "\r\n")
        return .connect(target: t, successReply: nil, failureReply: Self.http502, upstreamPreamble: Data(newHead.utf8) + rest)
    }

    static func parseAuthority(_ s: String, defaultPort: UInt16) -> ProxyTarget? {
        var hostPart = s
        var port = defaultPort
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return nil }
            hostPart = String(s[s.index(after: s.startIndex)..<close])
            let after = s[s.index(after: close)...]
            if after.hasPrefix(":") { guard let p = UInt16(after.dropFirst()) else { return nil }; port = p }
        } else if let colon = s.lastIndex(of: ":") {
            hostPart = String(s[..<colon])
            guard let p = UInt16(s[s.index(after: colon)...]) else { return nil }
            port = p
        }
        guard !hostPart.isEmpty, port != 0 else { return nil }
        return ProxyTarget(host: hostPart, port: port)
    }
}

public enum PAC {
    /// Proxy auto-config served at http://127.0.0.1:7590/proxy.pac while Combine is on.
    /// Local and private addresses stay direct, and every rule ends in DIRECT, so if Ply
    /// is not running, browsers fall back to a normal connection.
    public static func script(proxyPort: UInt16) -> String {
        """
        // Ply Combine. Generated; do not edit.
        function FindProxyForURL(url, host) {
          host = host.toLowerCase();
          if (isPlainHostName(host) || host === "localhost" || dnsDomainIs(host, ".local") ||
              dnsDomainIs(host, ".localhost") || dnsDomainIs(host, ".ts.net") || dnsDomainIs(host, ".home.arpa")) {
            return "DIRECT";
          }
          if (/^[0-9.]+$/.test(host)) {
            if (isInNet(host, "127.0.0.0", "255.0.0.0") || isInNet(host, "10.0.0.0", "255.0.0.0") ||
                isInNet(host, "172.16.0.0", "255.240.0.0") || isInNet(host, "192.168.0.0", "255.255.0.0") ||
                isInNet(host, "169.254.0.0", "255.255.0.0") || isInNet(host, "100.64.0.0", "255.192.0.0")) {
              return "DIRECT";
            }
          }
          if (host.indexOf(":") >= 0) { return "DIRECT"; }
          return "SOCKS5 127.0.0.1:\(proxyPort); SOCKS 127.0.0.1:\(proxyPort); DIRECT";
        }

        """
    }
}
