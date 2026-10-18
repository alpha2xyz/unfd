#if DEBUG
import AppKit
import SwiftUI

/// DEBUG only. `open unfd.app --args -snapshotDir /path` draws the panel and the permission screen
/// (system, light and dark) to PNG files without the screen (works while the Mac is locked), then quits.
enum PanelSnapshot {
    static func runIfAsked(model: AppModel) {
        guard let dir = UserDefaults.standard.string(forKey: "snapshotDir") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            for (name, look) in [("", nil), ("-light", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
                save(HomeView(model: model, forceTrusted: true), to: "\(dir)/panel\(name).png", look: look)
                save(PermissionView(model: model).padding(14), to: "\(dir)/permission\(name).png", look: look)
            }
            NSApplication.shared.terminate(nil)
        }
    }

    private static func save<V: View>(_ view: V, to path: String, look: NSAppearance.Name?) {
        let host = NSHostingView(rootView: view.frame(width: 320).environment(\.layoutDirection, .rightToLeft)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        if let look { window.appearance = NSAppearance(named: look) }
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
#endif
