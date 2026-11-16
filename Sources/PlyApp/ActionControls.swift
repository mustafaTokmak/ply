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
            button.buttonStyle(.borderedProminent).controlSize(.small)
        } else {
            button.buttonStyle(.borderless)
        }
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
