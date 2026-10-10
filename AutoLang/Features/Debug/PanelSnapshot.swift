#if DEBUG
import AppKit
import SwiftUI

/// DEBUG only. `open AutoLang.app --args -snapshotDir /path` draws the panel and the permission screen
/// to PNG files without the screen (works while the Mac is locked), then quits.
enum PanelSnapshot {
    static func runIfAsked(model: AppModel) {
        guard let dir = UserDefaults.standard.string(forKey: "snapshotDir") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            save(HomeView(model: model, forceTrusted: true), to: "\(dir)/panel.png")
            save(PermissionView(model: model).padding(14), to: "\(dir)/permission.png")
            NSApplication.shared.terminate(nil)
        }
    }

    private static func save<V: View>(_ view: V, to path: String) {
        let host = NSHostingView(rootView: view.frame(width: 320).environment(\.layoutDirection, .rightToLeft)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
#endif
