import SwiftUI
import AppKit
import ServiceManagement
import PlyCore
import PlyShared

@main
struct PlyMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared

    init() {
        PreviewRenderer.renderIfRequested()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(model)
        } label: {
            Image(systemName: model.menuBarSymbol)
                .accessibilityLabel(model.status?.summary ?? "Ply")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            await AppModel.shared.boot()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let firstLaunch = !UserDefaults.standard.bool(forKey: "shownWindow")
            if firstLaunch || !MainWindow.statusItemVisible() {
                UserDefaults.standard.set(true, forKey: "shownWindow")
                MainWindow.shared.show()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindow.shared.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }
}

final class LaunchAtLogin: LaunchAtLoginControlling {
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var status: StatusReport?
    @Published var busy: Set<ActionID> = []
    @Published var message: String?
    @Published var bootError: String?

    private(set) var engine: Engine?
    private var api: APIServer?
    private let loginItem = LaunchAtLogin()

    var menuBarSymbol: String {
        guard let s = status else { return "cable.connector" }
        if s.combine.running && s.combine.healthyLinks >= 2 { return "arrow.triangle.merge" }
        if let p = s.links.first(where: { $0.primary }) {
            switch p.kind {
            case .tether: return "cable.connector"
            case .wifi: return "wifi"
            default: return "network"
            }
        }
        return "wifi.slash"
    }

    func boot() async {
        let client = APIClient()
        if let h = await client.health() {
            if h.engine == "app" {
                // Another copy of the app is already running.
                NSApp.terminate(nil)
                return
            }
            // A headless `ply daemon` is running: take over from it.
            _ = try? await client.perform(.quit, [:])
            for _ in 0..<20 {
                if await client.health() == nil { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        let engine = Engine(mode: .app)
        engine.launchAtLogin = loginItem
        engine.onChange = { report in
            Task { @MainActor in AppModel.shared.status = report }
        }
        engine.onQuit = { NSApp.terminate(nil) }
        engine.onShowWindow = { Task { @MainActor in MainWindow.shared.show() } }
        let api = APIServer(engine: engine)
        do {
            try api.start()
        } catch {
            bootError = "Agent API unavailable: \(error)"
        }
        engine.start()
        self.engine = engine
        self.api = api
        _ = await run(.status)
    }

    func shutdown() {
        engine?.stop()
        api?.stop()
    }

    /// Every control in the menu goes through here, i.e. through the same `Engine.perform`
    /// that the HTTP API, CLI and MCP server use.
    @discardableResult
    func run(_ id: ActionID, _ params: Params = [:]) async -> JSONValue? {
        guard let engine else { return nil }
        busy.insert(id)
        defer { busy.remove(id) }
        do {
            let value = try await engine.perform(id, params)
            if id == .status, let r = try? value.decode(as: StatusReport.self) { status = r }
            message = nil
            return value
        } catch {
            let e = PlyError.wrap(error)
            message = e.message
            return nil
        }
    }
}
