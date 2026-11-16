import SwiftUI
import PlyCore

// Layout only. Interactive controls come from ActionControls.swift (see the rule there).

struct MenuView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let s = model.status {
                LinksCard(status: s)
                if let f = s.findings.first(where: { $0.severity == .warn || $0.severity == .error }) {
                    FindingBanner(finding: f)
                }
                usbSection(s)
                combineSection(s)
                speedSection(s)
            } else {
                HStack { ProgressView().controlSize(.small); Text("Reading network state...").foregroundStyle(.secondary) }
            }
            if let m = model.message ?? model.bootError {
                Text(m).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ply").font(.headline)
                Text(model.status?.summary ?? "Starting...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Image(systemName: model.menuBarSymbol)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
        }
    }

    private func usbSection(_ s: StatusReport) -> some View {
        MenuSection(title: "USB first") {
            SettingToggle(key: "preferUSB", title: "Prefer iPhone USB over Wi-Fi", value: s.settings.preferUSB)
            SettingToggle(key: "leaveIPhoneWiFiWhenUSB", title: "Leave iPhone's Wi-Fi hotspot when cabled", value: s.settings.leaveIPhoneWiFiWhenUSB)
            SettingToggle(key: "wifiOffWhenUSB", title: "Turn Wi-Fi off while cabled", value: s.settings.wifiOffWhenUSB)
            if !s.helper.installed {
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield").foregroundStyle(.orange)
                    Text("Putting iPhone USB first needs the helper.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    ActionButton(action: .installHelper, label: "Install helper", prominent: true)
                }
            }
        }
    }

    private func combineSection(_ s: StatusReport) -> some View {
        MenuSection(title: "Combine") {
            ActionToggle(title: "Combine Wi-Fi + iPhone", isOn: s.combine.running, on: .combineStart, off: .combineStop)
            SettingPicker(key: "split", options: [("connection", "Fastest (per connection)"), ("site", "Per site")], value: s.settings.split.rawValue)
            SettingToggle(key: "combineAuto", title: "Combine automatically when both are up", value: s.settings.combineAuto)
            if s.combine.running {
                Text("\(s.combine.activeFlows) active connections over \(s.combine.healthyLinks) healthy link\(s.combine.healthyLinks == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let w = s.combine.warning {
                Text(w).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func speedSection(_ s: StatusReport) -> some View {
        MenuSection(title: "Speed") {
            HStack {
                ActionButton(action: .speedTest, label: "Run speed test", systemImage: "speedometer")
                Spacer()
                Text("uses mobile data").font(.caption2).foregroundStyle(.tertiary)
            }
            if let t = s.lastSpeedTest {
                SpeedResultView(result: t)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            ActionButton(action: .diagnose, systemImage: "stethoscope")
            ActionButton(action: .agentPrompt, label: "Agent prompt", systemImage: "doc.on.clipboard", effect: .copy(field: "prompt"))
            Spacer()
            ActionButton(action: .about, label: "About", effect: .open(field: "source"))
            ActionButton(action: .quit, label: "Quit")
        }
        .font(.callout)
    }
}

struct MenuSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            content
        }
    }
}

struct LinksCard: View {
    let status: StatusReport

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(status.links.enumerated()), id: \.element.bsd) { idx, link in
                if idx > 0 { Divider().padding(.leading, 34) }
                LinkRow(link: link, combine: status.combine.links.first { $0.bsd == link.bsd }, combining: status.combine.running, usbState: status.usb.state)
            }
            if status.links.isEmpty {
                Text("No network links").foregroundStyle(.secondary).padding(10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

struct LinkRow: View {
    let link: LinkReport
    let combine: CombineLinkReport?
    let combining: Bool
    /// The status report's usb.state, used to explain why a plugged-in iPhone has no link.
    var usbState = ""

    var downText: String {
        guard link.kind == .tether else { return "not connected" }
        switch usbState {
        case "plugged-in-idle": return "plugged in · kept idle by macOS"
        case "plugged-in-no-hotspot": return "plugged in · not sharing"
        default: return "not connected"
        }
    }

    var icon: String {
        switch link.kind {
        case .tether: return "iphone"
        case .wifi: return link.up ? "wifi" : "wifi.slash"
        case .ethernet: return "network"
        case .other: return "questionmark.circle"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 22)
                .foregroundStyle(link.up ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(link.name).font(.callout.weight(.medium))
                    if link.primary { Badge(text: "IN USE", color: .green) }
                    if let c = combine, combining { Badge(text: c.health == "ok" ? "\(c.activeFlows) conn" : c.health, color: c.health == "ok" ? .blue : .orange) }
                }
                Text(link.up ? (link.ipv4.first ?? "connected") + " · \(link.bsd)" : downText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if link.up {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("↓ " + Rate.text(link.rxBps)).font(.caption.monospacedDigit())
                    Text("↑ " + Rate.text(link.txBps)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}

struct FindingBanner: View {
    let finding: Finding

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: finding.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(finding.severity == .error ? .red : .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(finding.title).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text(finding.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let fix = finding.fix {
                    ActionButton(action: fix, params: finding.fixParams ?? [:], prominent: true)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.10)))
    }
}

struct SpeedResultView: View {
    let result: SpeedTestResult

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(result.each, id: \.bsd) { r in
                HStack {
                    Text(r.name).font(.caption)
                    Spacer()
                    Text(r.error == nil ? String(format: "%.1f Mbps", r.mbps) : "failed").font(.caption.monospacedDigit())
                }
            }
            if let c = result.combinedMbps {
                HStack {
                    Text("All together").font(.caption.weight(.semibold))
                    Spacer()
                    Text(String(format: "%.1f Mbps", c)).font(.caption.monospacedDigit().weight(.semibold))
                    if let g = result.gainPercent { Text(String(format: "%+.0f%%", g)).font(.caption2).foregroundStyle(g > 5 ? .green : .secondary) }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }
}

enum Rate {
    static func text(_ bytesPerSecond: Double) -> String {
        let mbps = bytesPerSecond * 8 / 1_000_000
        if mbps < 0.05 { return "0 Mb/s" }
        return mbps >= 10 ? String(format: "%.0f Mb/s", mbps) : String(format: "%.1f Mb/s", mbps)
    }
}
