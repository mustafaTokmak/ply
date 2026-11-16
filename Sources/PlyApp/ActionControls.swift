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
    @EnvironmentObject var model: AppModel

    var body: some View {
        let title = label ?? Registry.spec(action).title
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
                .foregroundStyle(isOn ? AnyShapeStyle(Brand.rainbow) : AnyShapeStyle(Color.secondary))
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
            Toggle("", isOn: Binding(get: { value }, set: { new in
                Task { _ = await model.run(.updateSettings, [key: .bool(new)]) }
            }))
            .labelsHidden()
            .toggleStyle(.switch)
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
            Toggle("", isOn: Binding(get: { isOn }, set: { new in
                Task { _ = await model.run(new ? on : off) }
            }))
            .labelsHidden()
            .toggleStyle(.switch)
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
            Toggle("", isOn: Binding(get: { isOn }, set: { new in
                Task { _ = await model.run(new ? on : off, new ? onParams : [:]) }
            }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
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
            Text(title).font(.callout)
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { value }, set: { new in
                Task { _ = await model.run(.updateSettings, [key: .bool(new)]) }
            }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
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
        Picker("", selection: Binding(get: { value }, set: { new in
            Task { _ = await model.run(.updateSettings, [key: .string(new)]) }
        })) {
            ForEach(options, id: \.value) { o in Text(o.label).tag(o.value) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .help(PlyCore.Settings.fields.first { $0.key == key }?.summary ?? "")
    }
}
