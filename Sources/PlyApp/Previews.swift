import SwiftUI
import AppKit
import PlyCore
import PlyShared

/// `Ply --render-previews <dir> [--status-json <file>]` renders the real menu UI to PNGs
/// (used for the README and to check the layout without clicking through the app).
/// The built-in states use example numbers, not measurements. With `--status-json`
/// (the output of `ply status --json`), it also renders that real state as menu-live-*.
enum PreviewRenderer {
    @MainActor
    static func renderIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--render-previews") else { return }
        let dir = URL(fileURLWithPath: i + 1 < args.count ? args[i + 1] : "previews")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var scenes: [(String, StatusReport, ColorScheme)] = [
            ("menu-usb-light", PreviewSamples.usbFirst(), .light),
            ("menu-usb-dark", PreviewSamples.usbFirst(), .dark),
            ("menu-combine-light", PreviewSamples.combining(), .light),
            ("menu-combine-dark", PreviewSamples.combining(), .dark),
            ("menu-fix-light", PreviewSamples.wifiFirst(), .light),
            ("menu-idle-light", PreviewSamples.usbIdle(), .light),
            ("menu-idle-dark", PreviewSamples.usbIdle(), .dark),
        ]
        if let j = args.firstIndex(of: "--status-json"), j + 1 < args.count {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: args[j + 1]))
                let live = try JSONCoding.decoder.decode(StatusReport.self, from: data)
                scenes += [("menu-live-light", live, .light), ("menu-live-dark", live, .dark)]
            } catch {
                print("could not read status JSON: \(error)")
            }
        }
        // Every scene in both menu modes: simple as <name>, advanced as <name> with "-advanced".
        scenes = scenes.flatMap { name, report, scheme -> [(String, StatusReport, ColorScheme)] in
            var simple = report, advanced = report
            simple.settings.uiMode = .simple
            advanced.settings.uiMode = .advanced
            let parts = name.split(separator: "-")
            let advancedName = (parts.dropLast() + ["advanced", parts.last!]).joined(separator: "-")
            return [(name, simple, scheme), (advancedName, advanced, scheme)]
        }
        _ = NSApplication.shared
        for (name, report, scheme) in scenes {
            let model = AppModel.shared
            model.status = report
            let view = MenuView()
                .environmentObject(model)
                .background((scheme == .dark ? Color(nsColor: NSColor(white: 0.17, alpha: 1)) : Color(nsColor: NSColor(white: 0.965, alpha: 1))).ignoresSafeArea())
            // Render through a real (offscreen) window so native controls draw too.
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.display()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { print("could not render \(name)"); continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                let url = dir.appendingPathComponent("\(name).png")
                try? png.write(to: url)
                print("wrote \(url.path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
            }
        }
        exit(0)
    }
}
