import AppKit
import ApplicationServices
import SwiftUI

/// A small "ع" / "EN" tag under the cursor for a moment after the app switches,
/// because macOS shows its own language hint only when he switches by hand.
final class CaretIndicator {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ lang: Lang, at element: AXUIElement, settle: Bool = true) {
        guard let axRect = Self.caretRect(element) else { return }
        // Switching desktop spaces slides the window for a moment: place the tag again once it settles.
        if settle {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated { if self?.panel?.alphaValue == 1 { self?.show(lang, at: element, settle: false) } }
            }
        }
        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView:
            Text(verbatim: lang.menuBarLabel)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
                .fixedSize())
        let size = panel.contentView?.fittingSize ?? CGSize(width: 34, height: 24)

        // Accessibility uses a top-left origin on the main screen; windows use bottom-left.
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        var origin = CGPoint(x: axRect.minX, y: mainHeight - axRect.maxY - size.height - 4)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: axRect.midX, y: mainHeight - axRect.midY)) }) {
            let f = screen.visibleFrame
            origin.x = min(max(origin.x, f.minX + 4), f.maxX - size.width - 4)
            if origin.y < f.minY + 4 { origin.y = mainHeight - axRect.minY + 4 }   // no room below: show above
        }
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        // Stop a fade still running from the previous tag, or it keeps pulling this one toward invisible.
        NSAnimationContext.runAnimationGroup { $0.duration = 0; panel.animator().alphaValue = 1 }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        guard settle else { return }   // keep the original hide time
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                NSAnimationContext.runAnimationGroup { $0.duration = 0.25; self?.panel?.animator().alphaValue = 0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    MainActor.assumeIsolated { if self?.panel?.alphaValue == 0 { self?.panel?.orderOut(nil) } }
                }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }

    /// The text cursor's rectangle on screen, else the field's own rectangle.
    static func caretRect(_ element: AXUIElement) -> CGRect? {
        if let range = AX.value(element, kAXSelectedTextRangeAttribute) {
            var bounds: AnyObject?
            if AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds) == .success,
               let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() {
                var rect = CGRect.zero
                if AXValueGetValue(bounds as! AXValue, .cgRect, &rect), rect.height > 0, rect.origin != .zero { return rect }
            }
        }
        guard let pos = AX.value(element, kAXPositionAttribute), let size = AX.value(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(x: point.x + 4, y: point.y, width: 1, height: extent.height)
    }
}
