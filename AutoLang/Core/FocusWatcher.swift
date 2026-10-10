import AppKit
import ApplicationServices

/// Calls `onFocusChange` when the cursor moves to another field, or the same field shows another chat.
/// Main signal: an Accessibility observer on the front app (same pattern as Input Source Pro); every
/// notification is handled, even for the same element, because leaving and coming back must re-check.
/// Fallback: a 0.4 s check of a cheap "place" (element + window title + WhatsApp chat name) for apps whose
/// observer stays silent, such as a chat change inside WhatsApp that keeps the same composer field.
final class FocusWatcher {
    var onFocusChange: (AXUIElement, NSRunningApplication) -> Void = { _, _ in }

    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var lastElement: AXUIElement?
    private var lastPlace = ""
    private var whatsAppHeader: AXUIElement?
    private var timer: Timer?
    private var activationToken: NSObjectProtocol?

    func start() {
        guard AXIsProcessTrusted(), timer == nil else { return }
        activationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.attachToFrontApp() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(force: false) }
        }
        attachToFrontApp()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let activationToken { NSWorkspace.shared.notificationCenter.removeObserver(activationToken) }
        activationToken = nil
        detach()
    }

    func recheck() { check(force: true) }

    private func attachToFrontApp() {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return }
        if app.processIdentifier != observedPID {
            detach()
            AX.enableManualAccessibility(pid: app.processIdentifier)
            var created: AXObserver?
            let callback: AXObserverCallback = { _, _, _, refcon in
                guard let refcon else { return }
                let watcher = Unmanaged<FocusWatcher>.fromOpaque(refcon).takeUnretainedValue()
                MainActor.assumeIsolated { watcher.check(force: true) }
            }
            if AXObserverCreate(app.processIdentifier, callback, &created) == .success, let created {
                let appElement = AXUIElementCreateApplication(app.processIdentifier)
                let refcon = Unmanaged.passUnretained(self).toOpaque()
                for name in [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification] {
                    AXObserverAddNotification(created, appElement, name as CFString, refcon)
                }
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
                observer = created
                observedPID = app.processIdentifier
            }
        }
        check(force: true)
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedPID = 0
        whatsAppHeader = nil
    }

    private func check(force: Bool) {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
              let element = AX.focusedElement(pid: app.processIdentifier) else { return }
        let place = place(of: element, app: app)
        if !force, let lastElement, CFEqual(lastElement, element), place == lastPlace { return }
        lastElement = element
        lastPlace = place
        onFocusChange(element, app)
    }

    /// Window title, plus the chat name in WhatsApp (its window title never changes).
    private func place(of element: AXUIElement, app: NSRunningApplication) -> String {
        let window = AX.element(element, kAXWindowAttribute)
        var place = "\(app.processIdentifier)|" + (window.map { AX.string($0, kAXTitleAttribute) } ?? "")
        if app.bundleIdentifier == "net.whatsapp.WhatsApp", let window {
            if whatsAppHeader == nil || AX.string(whatsAppHeader!, kAXIdentifierAttribute).isEmpty {
                whatsAppHeader = ContextReader.findWhatsAppHeader(window)
            }
            if let header = whatsAppHeader { place += "|" + AX.string(header, kAXDescriptionAttribute) }
        }
        return place
    }
}
