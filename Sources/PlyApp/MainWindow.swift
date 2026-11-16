import SwiftUI
import AppKit

/// The menu in a normal window. Ply lives in the menu bar, but on a MacBook with a notch
/// and many menu bar apps macOS hides icons that don't fit, so opening Ply would seem to
/// do nothing. The first launch, opening the app again, or a launch with the icon hidden
/// shows this.
@MainActor
final class MainWindow {
    static let shared = MainWindow()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let root = VStack(alignment: .leading, spacing: 0) {
                MenuView().environmentObject(AppModel.shared)
                Divider()
                Text("Ply lives in the menu bar. If its icon is missing, the menu bar is full: quit a few menu bar apps, or open Ply again to get this window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 316, alignment: .leading)
                    .padding(12)
            }
            let w = NSWindow(contentViewController: NSHostingController(rootView: root))
            w.title = "Ply"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Whether macOS is actually drawing Ply's menu bar icon.
    static func statusItemVisible() -> Bool {
        for w in NSApp.windows where String(describing: type(of: w)).contains("StatusBarWindow") {
            guard let screen = w.screen, w.occlusionState.contains(.visible) else { continue }
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
               w.frame.midX > left.maxX, w.frame.midX < right.minX {
                continue // under the notch
            }
            return true
        }
        return false
    }
}
