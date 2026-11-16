import SwiftUI
import AppKit
import PlyCore

// The ONLY file in the app allowed to create interactive controls.
// Every control here runs a registry action through AppModel.run, which is the
// same Engine.perform the HTTP API, CLI and MCP server use. A test scans the
// other app files and fails the build if they create Buttons/Toggles/Pickers.

/// What to do with an action's JSON result in the UI (purely presentational).
enum ResultEffect {
    case none
    case copy(field: String)
    case open(field: String)

    @MainActor func apply(_ value: JSONValue?) {
        guard let value else { return }
        switch self {
        case .none:
            break
        case .copy(let field):
            if let text = value[field]?.stringValue {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                AppModel.shared.message = "Copied to the clipboard."
            }
        case .open(let field):
            if let s = value[field]?.stringValue, let url = URL(string: s) { NSWorkspace.shared.open(url) }
        }
    }
}

struct ActionButton: View {
    let action: ActionID
    var params: Params = [:]
    var label: String?
    var systemImage: String?
    var effect: ResultEffect = .none
    var prominent = false
    /// A glass capsule button (macOS 26), bordered before that.
    var glass = false
    /// The speed test's own button: a glass dial in a glass capsule; the dial lights up while it runs.
    var dial = false
    @EnvironmentObject var model: AppModel

    var body: some View {
        let title = label ?? Registry.spec(action).title
        if dial {
            Button {
                Task { effect.apply(await model.run(action, params)) }
            } label: {
                DialLabel(title: title, running: model.busy.contains(action))
            }
            .buttonStyle(.plain)
            .disabled(model.busy.contains(action))
            .help(Registry.spec(action).summary)
        } else {
            standard(title)
        }
    }

    @ViewBuilder private func standard(_ title: String) -> some View {
        let button = Button {
            Task { effect.apply(await model.run(action, params)) }
        } label: {
            HStack(spacing: 5) {
                if model.busy.contains(action) {
                    ProgressView().controlSize(.mini)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
        }
        .disabled(model.busy.contains(action))
        .help(Registry.spec(action).summary)
        if prominent {
            button.prominentStyle()
        } else if glass {
            button.glassStyle()
        } else {
            button.buttonStyle(.borderless)
        }
    }
}

private struct DialLabel: View {
    let title: String?
    let running: Bool
    var size: CGFloat = 28
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                if let idle = Art.image("orb-idle"), let on = Art.image("orb-on") {
                    Image(nsImage: idle).resizable().opacity(running ? 0 : 1)
                    Image(nsImage: on).resizable().opacity(running ? (pulse ? 1 : 0.55) : 0)
                } else {
                    Image(systemName: "speedometer").foregroundStyle(running ? Brand.mint : Color.secondary)
                }
            }
            .frame(width: size, height: size)
            .shadow(color: running ? Brand.mint.opacity(0.7) : .clear, radius: 6)
            if let title {
                Text(running ? "Testing..." : title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(running ? Brand.mint : Color.primary)
            }
        }
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.3), value: running)
        .onChange(of: running) { r in
            if r {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
            } else {
                pulse = false
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func prominentStyle() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent).controlSize(.regular)
        } else {
            buttonStyle(.borderedProminent).controlSize(.small)
        }
        #else
        buttonStyle(.borderedProminent).controlSize(.small)
        #endif
    }

    @ViewBuilder
    func glassStyle() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            buttonStyle(.glass).controlSize(.regular)
        } else {
            buttonStyle(.bordered).controlSize(.small)
        }
        #else
        buttonStyle(.bordered).controlSize(.small)
        #endif
    }
}

/// The big row used in the simple menu: icon, title, one line of state, and a switch.
private struct FeatureRow<Trailing: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    let isOn: Bool
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isOn ? Brand.accent : Color.secondary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.primary.opacity(0.06)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(12)
        .glassCard(cornerRadius: 18)
    }
}

/// The speed test in the simple menu: same row as the switches, with the glass dial as its button.
struct SpeedTestRow: View {
    let subtitle: String
    @EnvironmentObject var model: AppModel

    var body: some View {
        let running = model.busy.contains(.speedTest)
        FeatureRow(icon: "speedometer", title: "Speed test", subtitle: running ? "Testing each link, then both together..." : subtitle, isOn: running) {
            Button {
                Task { _ = await model.run(.speedTest) }
            } label: {
                DialLabel(title: nil, running: running, size: 40)
            }
            .buttonStyle(.plain)
            .disabled(running)
        }
        .help(Registry.spec(.speedTest).summary)
    }
}

/// A big switch for one boolean setting, via update_settings.
struct FeatureSettingSwitch: View {
    let key: String
    let icon: String
    let title: String
    let subtitle: String
    let value: Bool
    @EnvironmentObject var model: AppModel

    var body: some View {
        FeatureRow(icon: icon, title: title, subtitle: subtitle, isOn: value) {
            PlySwitch(isOn: value, kind: key == "preferUSB" ? .plug : .bead) { new in
                Task { _ = await model.run(.updateSettings, [key: .bool(new)]) }
            }
        }
        .help(PlyCore.Settings.fields.first { $0.key == key }?.summary ?? "")
    }
}

/// A big switch whose on/off runs two different actions, e.g. combine_start / combine_stop.
struct FeatureActionSwitch: View {
    let icon: String
    let title: String
    let subtitle: String
    let isOn: Bool
    let on: ActionID
    let off: ActionID
    @EnvironmentObject var model: AppModel

    var body: some View {
        let busy = model.busy.contains(on) || model.busy.contains(off)
        FeatureRow(icon: icon, title: title, subtitle: subtitle, isOn: isOn) {
            if busy { ProgressView().controlSize(.small) }
            PlySwitch(isOn: isOn, kind: on == .combineStart ? .bridge : .bead) { new in
                Task { _ = await model.run(new ? on : off) }
            }
            .disabled(busy)
        }
        .help(Registry.spec(on).summary)
    }
}

/// A switch whose on/off runs two different actions (e.g. combine_start / combine_stop).
struct ActionToggle: View {
    let title: String
    let isOn: Bool
    let on: ActionID
    let off: ActionID
    var onParams: Params = [:]
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack {
            Text(title).font(.body.weight(.medium))
            Spacer(minLength: 8)
            if model.busy.contains(on) || model.busy.contains(off) { ProgressView().controlSize(.mini) }
            PlySwitch(isOn: isOn, kind: on == .combineStart ? .bridge : .bead) { new in
                Task { _ = await model.run(new ? on : off, new ? onParams : [:]) }
            }
            .disabled(model.busy.contains(on) || model.busy.contains(off))
        }
        .help(Registry.spec(on).summary)
    }
}

/// A switch for one boolean setting, via update_settings.
struct SettingToggle: View {
    let key: String
    let title: String
    let value: Bool
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack {
            Text(title).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            PlySwitch(isOn: value, kind: key == "preferUSB" ? .plug : .bead) { new in
                Task { _ = await model.run(.updateSettings, [key: .bool(new)]) }
            }
        }
        .help(PlyCore.Settings.fields.first { $0.key == key }?.summary ?? "")
    }
}

/// A segmented choice for one enum setting, via update_settings.
struct SettingPicker: View {
    let key: String
    let options: [(value: String, label: String)]
    let value: String
    @EnvironmentObject var model: AppModel

    var body: some View {
        PlySegments(options: options, value: value) { new in
            Task { _ = await model.run(.updateSettings, [key: .string(new)]) }
        }
        .help(PlyCore.Settings.fields.first { $0.key == key }?.summary ?? "")
    }
}


/// Ply's own switch: a glass capsule track with a white knob, solid accent when on.
/// Private to this file so every use goes through one of the controls above.
private struct PlySwitch: View {
    /// Each feature gets its own switch: the cable plugs in for "iPhone first", the two links
    /// join for "combine", and every other setting is a glass bead.
    enum Kind { case plug, bridge, bead }
    let isOn: Bool
    let kind: Kind
    let set: (Bool) -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button { set(!isOn) } label: {
            Group {
                if let art = SwitchArt.load(kind) {
                    ArtSwitch(art: art, isOn: isOn, height: kind == .bead ? 21 : 34)
                } else {
                    drawn
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.72), value: isOn)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.75)
        .accessibilityLabel("Switch")
        .accessibilityValue(isOn ? "on" : "off")
    }

    /// Code-drawn fallback, used when the artwork is missing (e.g. `swift run` outside the app bundle).
    @ViewBuilder private var drawn: some View {
        switch kind {
        case .plug: PlugCable(isOn: isOn, height: 28)
        case .bridge: LinkBridge(isOn: isOn, height: 24)
        case .bead: GlassBead(isOn: isOn, height: 20)
        }
    }
}

/// Rendered artwork for a switch: one transparent PNG per state, in Contents/Resources/Switches.
private struct SwitchArt {
    let off: NSImage
    let on: NSImage

    @MainActor static func load(_ kind: PlySwitch.Kind) -> SwitchArt? {
        let name: String
        switch kind {
        case .plug: name = "plug"
        case .bridge: name = "bridge"
        case .bead: name = "bead"
        }
        guard let off = Art.image("\(name)-off"), let on = Art.image("\(name)-on") else { return nil }
        return SwitchArt(off: off, on: on)
    }
}

/// Cross-fades between the two artwork states, with a small press of scale on change.
private struct ArtSwitch: View {
    let art: SwitchArt
    let isOn: Bool
    let height: CGFloat

    var body: some View {
        let ratio = art.off.size.width / max(art.off.size.height, 1)
        ZStack {
            Image(nsImage: art.off).resizable().interpolation(.high).opacity(isOn ? 0 : 1)
            Image(nsImage: art.on).resizable().interpolation(.high).opacity(isOn ? 1 : 0)
        }
        .frame(width: height * ratio, height: height)
        .contentShape(Rectangle())
    }
}

/// The "iPhone cable first" switch, drawn like the real thing: a glass tile with a USB-C port
/// and a white plug on a cable beside it. On, the plug sits in the port and glows.
private struct PlugCable: View {
    let isOn: Bool
    let height: CGFloat

    var body: some View {
        let h = height, w = h * 2.95
        let tipW = h * 0.36, tipH = h * 0.22
        let bodyW = h * 0.74, bodyH = h * 0.46
        let reliefW = h * 0.2, reliefH = h * 0.28
        let bodyX = isOn ? h * 0.4 : h * 1.1 + tipW
        let cableX = bodyX + bodyW + reliefW
        let tile = RoundedRectangle(cornerRadius: h * 0.26, style: .continuous)
        let plugBody = RoundedRectangle(cornerRadius: h * 0.13, style: .continuous)
        ZStack(alignment: .topLeading) {
            tile.fill(Color.white.opacity(0.35))
                .frame(width: h, height: h)
                .glassy(tile)
                .sheen(tile)
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            // USB-C port: dark rim, silver inside, a tongue in the middle.
            Capsule().fill(Color(white: 0.28))
                .overlay(Capsule().fill(Color(white: 0.78)).padding(h * 0.035))
                .overlay(Capsule().fill(Color(white: 0.32)).frame(width: h * 0.28, height: max(1, h * 0.045)))
                .frame(width: h * 0.52, height: h * 0.2)
                .offset(x: h * 0.24, y: h * 0.4)
                .opacity(isOn ? 0 : 1)
            CableShape(startX: cableX - 1, y: h / 2, end: CGPoint(x: w - h * 0.1, y: h + h * 0.15))
                .stroke(Color(white: 0.78), style: StrokeStyle(lineWidth: h * 0.19, lineCap: .round))
            CableShape(startX: cableX - 1, y: h / 2, end: CGPoint(x: w - h * 0.1, y: h + h * 0.15))
                .stroke(Color.white, style: StrokeStyle(lineWidth: h * 0.14, lineCap: .round))
            // Metal tip; it disappears into the port when on.
            RoundedRectangle(cornerRadius: h * 0.09, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.96), Color(white: 0.7)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: h * 0.09, style: .continuous).strokeBorder(Color(white: 0.5), lineWidth: 0.5))
                .overlay(Capsule().fill(Color(white: 0.45)).frame(width: tipW * 0.55, height: max(1, h * 0.04)))
                .frame(width: tipW, height: tipH)
                .offset(x: bodyX - tipW + 1, y: (h - tipH) / 2)
                .opacity(isOn ? 0 : 1)
            // Strain relief between body and cable.
            RoundedRectangle(cornerRadius: h * 0.07, style: .continuous)
                .fill(LinearGradient(colors: [Color.white, Color(white: 0.86)], startPoint: .top, endPoint: .bottom))
                .frame(width: reliefW + 2, height: reliefH)
                .offset(x: bodyX + bodyW - 1, y: (h - reliefH) / 2)
            // Body: white plastic off, glowing glass on.
            plugBody
                .fill(isOn ? AnyShapeStyle(Brand.accent.opacity(0.8)) : AnyShapeStyle(LinearGradient(colors: [Color.white, Color(white: 0.88)], startPoint: .top, endPoint: .bottom)))
                .overlay(plugBody.fill(LinearGradient(colors: [.white.opacity(isOn ? 0.6 : 0), .clear], startPoint: .top, endPoint: .center)))
                .overlay(plugBody.strokeBorder(isOn ? Color.white.opacity(0.75) : Color.black.opacity(0.12), lineWidth: 0.6))
                .shadow(color: isOn ? Brand.accent.opacity(0.85) : .black.opacity(0.22), radius: isOn ? 6 : 1.5, y: isOn ? 0 : 1)
                .frame(width: bodyW, height: bodyH)
                .offset(x: bodyX, y: (h - bodyH) / 2)
        }
        .frame(width: w, height: h, alignment: .topLeading)
        .contentShape(Rectangle())
    }
}

/// The cable leaves the plug to the right and curls down out of the switch.
private struct CableShape: Shape {
    var startX: CGFloat
    let y: CGFloat
    let end: CGPoint
    var animatableData: CGFloat {
        get { startX }
        set { startX = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: startX, y: y))
        p.addCurve(to: end,
                   control1: CGPoint(x: startX + (end.x - startX) * 0.85, y: y),
                   control2: CGPoint(x: end.x, y: y + (end.y - y) * 0.35))
        return p
    }
}

/// Two glass pads, Wi-Fi and iPhone, that slide together and light the channel between them.
private struct LinkBridge: View {
    let isOn: Bool
    let height: CGFloat

    var body: some View {
        let h = height, w = h * 2.75
        let leftX = isOn ? w / 2 - h + h * 0.12 : 0
        let rightX = isOn ? w / 2 - h * 0.12 : w - h
        ZStack(alignment: .leading) {
            Capsule()
                .fill(isOn ? Brand.accent : Color.primary.opacity(0.14))
                .frame(width: rightX - leftX, height: h * 0.26)
                .shadow(color: isOn ? Brand.accent : .clear, radius: 4)
                .offset(x: leftX + h / 2)
            pad("wifi").offset(x: leftX)
            pad("iphone").offset(x: rightX)
        }
        .frame(width: w, height: h, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func pad(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: height * 0.42, weight: .semibold))
            .foregroundStyle(isOn ? Brand.accent : Color.secondary)
            .frame(width: height, height: height)
            .background(Circle().fill(isOn ? Brand.accent.opacity(0.18) : Color.primary.opacity(0.05)))
            .glassy(Circle())
            .sheen(Circle())
            .shadow(color: isOn ? Brand.accent.opacity(0.5) : .black.opacity(0.08), radius: isOn ? 5 : 2)
    }
}

/// A glass bead in a groove; it takes the accent and glows when on.
private struct GlassBead: View {
    let isOn: Bool
    let height: CGFloat

    var body: some View {
        let h = height, w = h * 1.9
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Brand.accent.opacity(0.2) : Color.primary.opacity(0.07))
                .frame(width: w, height: h)
                .glassy(Capsule())
                .sheen(Capsule())
            Circle()
                .fill(isOn ? Brand.accent : Color.white)
                .overlay(Circle().fill(LinearGradient(colors: [.white.opacity(isOn ? 0.55 : 0.9), .clear], startPoint: .top, endPoint: .center)).padding(1.5))
                .shadow(color: isOn ? Brand.accent.opacity(0.7) : .black.opacity(0.22), radius: isOn ? 4 : 1.5, y: isOn ? 0 : 1)
                .frame(width: h - 4, height: h - 4)
                .padding(2)
        }
        .frame(width: w, height: h)
        .contentShape(Capsule())
    }
}

private extension View {
    /// A thin bright rim along the top edge, like light catching glass.
    func sheen<S: InsettableShape>(_ shape: S) -> some View {
        overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 0.8))
    }
}

private extension View {
    @ViewBuilder
    func glassy<S: Shape>(_ shape: S) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            glassEffect(Glass.clear.interactive(), in: shape)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

/// Ply's own segmented choice: a clear glass capsule with a solid accent pill that slides to the selection.
private struct PlySegments: View {
    let options: [(value: String, label: String)]
    let value: String
    let set: (String) -> Void
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { o in
                Button { if o.value != value { set(o.value) } } label: {
                    Text(o.label)
                        .font(.callout.weight(o.value == value ? .semibold : .regular))
                        .foregroundStyle(o.value == value ? Color.black.opacity(0.78) : Color.primary)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background {
                            if o.value == value {
                                GlowPill(height: 26).matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(o.value == value ? .isSelected : [])
            }
        }
        .padding(3)
        .frame(height: 32)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: value)
        .background { GlassTrack(height: 32) }
        // Glass goes on the whole control so the labels and lens sit on top of it, as on the cards.
        .glassCapsule()
    }
}

/// The clear glass track of the sliding lens: frosted fill, crisp white rim, hairline edge.
/// Drawn rather than rendered artwork so it stays sharp on 1x displays.
private struct GlassTrack: View {
    let height: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        Capsule()
            .fill(Color.white.opacity(dark ? 0.07 : 0.6))
            .overlay(Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(dark ? 0.35 : 1), .white.opacity(dark ? 0.06 : 0.4)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .overlay(Capsule().strokeBorder(Color.black.opacity(dark ? 0.5 : 0.11), lineWidth: 0.5).padding(-0.5))
            .shadow(color: .black.opacity(dark ? 0.3 : 0.07), radius: 2, y: 1)
            .frame(height: height)
    }
}

/// The lit selection: a mint glass lens with a white rim, a top sheen and a soft glow.
private struct GlowPill: View {
    let height: CGFloat

    var body: some View {
        Capsule()
            .fill(LinearGradient(colors: [Color(red: 0.70, green: 0.94, blue: 0.80), Brand.mint], startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .top) {
                Capsule()
                    .fill(LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .frame(height: height * 0.48)
                    .padding(.horizontal, height * 0.32)
                    .padding(.top, 1.5)
            }
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.95), lineWidth: 1))
            .shadow(color: Brand.mint.opacity(0.75), radius: 5)
            .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
    }
}

/// Rendered glass artwork shipped in Contents/Resources/Switches.
enum Art {
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor static func image(_ name: String) -> NSImage? {
        if let i = cache[name] { return i }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Switches"),
              let i = NSImage(contentsOf: url) else { return nil }
        cache[name] = i
        return i
    }

    /// A capsule-shaped image sized so its round ends stay round at any width.
    @MainActor static func capsule(_ name: String, height: CGFloat) -> Image? {
        let key = "\(name)@\(height)"
        if cache[key] == nil {
            guard let src = image(name), let copy = src.copy() as? NSImage, let rep = src.representations.first else { return nil }
            copy.size = NSSize(width: CGFloat(rep.pixelsWide) * height / CGFloat(rep.pixelsHigh), height: height)
            cache[key] = copy
        }
        let r = height / 2
        return cache[key].map { Image(nsImage: $0).resizable(capInsets: EdgeInsets(top: r, leading: r, bottom: r, trailing: r), resizingMode: .stretch) }
    }
}

private extension View {
    @ViewBuilder
    func glassCapsule() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            glassEffect(Glass.clear.interactive(), in: Capsule())
        } else {
            background(Capsule().fill(Color.primary.opacity(0.08)))
        }
        #else
        background(Capsule().fill(Color.primary.opacity(0.08)))
        #endif
    }
}
