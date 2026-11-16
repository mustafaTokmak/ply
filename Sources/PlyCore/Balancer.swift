import Foundation

public struct BalancerLink: Equatable, Sendable {
    public var name: String
    /// Relative capacity (any unit). Links with more capacity get proportionally more connections.
    public var weight: Double
    public var active: Int
    public var healthy: Bool

    public init(name: String, weight: Double, active: Int, healthy: Bool) {
        self.name = name
        self.weight = weight
        self.active = active
        self.healthy = healthy
    }
}

/// Chooses a link for each new connection: weighted least-connections,
/// optionally sticky per site.
public final class Balancer {
    public var split: SplitMode
    public var stickySeconds: TimeInterval = 600
    private var sticky: [String: (link: String, until: Date)] = [:]

    public init(split: SplitMode) {
        self.split = split
    }

    public func choose(host: String, links: [BalancerLink], excluding: Set<String> = [], now: Date = Date()) -> String? {
        let usable = links.filter { !excluding.contains($0.name) }
        var candidates = usable.filter(\.healthy)
        if candidates.isEmpty { candidates = usable }
        guard !candidates.isEmpty else { return nil }

        let key = Balancer.siteKey(host)
        if split == .site, let s = sticky[key], s.until > now, candidates.contains(where: { $0.name == s.link }) {
            sticky[key] = (s.link, now.addingTimeInterval(stickySeconds))
            return s.link
        }
        let best = candidates.min { a, b in
            let sa = Double(a.active + 1) / max(a.weight, 0.0001)
            let sb = Double(b.active + 1) / max(b.weight, 0.0001)
            if sa != sb { return sa < sb }
            if a.weight != b.weight { return a.weight > b.weight }
            return a.name < b.name
        }!
        if split == .site {
            sticky[key] = (best.name, now.addingTimeInterval(stickySeconds))
            if sticky.count > 4096 { sticky = sticky.filter { $0.value.until > now } }
        }
        return best.name
    }

    /// Approximate registrable domain: "a.b.example.co.uk" -> "example.co.uk".
    public static func siteKey(_ host: String) -> String {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if h.contains(":") || h.split(separator: ".").allSatisfy({ $0.allSatisfy(\.isNumber) }) { return h }
        let parts = h.split(separator: ".").map(String.init)
        guard parts.count > 2 else { return h }
        let tld = parts[parts.count - 1]
        let sld = parts[parts.count - 2]
        let secondLevel: Set<String> = ["co", "com", "net", "org", "gov", "ac", "edu", "ne", "or", "gen", "web", "biz"]
        if tld.count == 2 && secondLevel.contains(sld) {
            return parts.suffix(3).joined(separator: ".")
        }
        return parts.suffix(2).joined(separator: ".")
    }

    /// Weights from observed peak throughput, floored so a quiet link still gets traffic and can prove itself.
    public static func weights(peaks: [String: Double]) -> [String: Double] {
        let maxPeak = peaks.values.max() ?? 0
        guard maxPeak > 0 else { return peaks.mapValues { _ in 1 } }
        return peaks.mapValues { max($0, maxPeak * 0.25) / maxPeak }
    }
}
