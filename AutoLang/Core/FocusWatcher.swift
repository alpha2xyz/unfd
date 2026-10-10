import AppKit
import ApplicationServices

/// Calls `onFocusChange` when the cursor moves to another element in the app in front.
/// Main signal: an Accessibility observer on the front app (same pattern as Input Source Pro).
/// Fallback: a slow timer for apps whose observer stays silent.
final class FocusWatcher {
    var onFocusChange: (AXUIElement, NSRunningApplication) -> Void = { _, _ in }

    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var lastElement: AXUIElement?
    private var timer: Timer?
    private var activationToken: NSObjectProtocol?

    func start() {
        guard AXIsProcessTrusted(), timer == nil else { return }
        activationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.attachToFrontApp() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        attachToFrontApp()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let activationToken { NSWorkspace.shared.notificationCenter.removeObserver(activationToken) }
        activationToken = nil
        detach()
    }

    /// Forget the last element so the next check fires even if the cursor did not move.
    func recheck() {
        lastElement = nil
        check()
    }

    private func attachToFrontApp() {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return }
        if app.processIdentifier != observedPID {
            detach()
            AX.enableManualAccessibility(pid: app.processIdentifier)
            var created: AXObserver?
            let callback: AXObserverCallback = { _, _, _, refcon in
                guard let refcon else { return }
                let watcher = Unmanaged<FocusWatcher>.fromOpaque(refcon).takeUnretainedValue()
                MainActor.assumeIsolated { watcher.check() }
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
        lastElement = nil
        check()
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedPID = 0
    }

    private func check() {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
              let element = AX.focusedElement(pid: app.processIdentifier) else { return }
        if let lastElement, CFEqual(lastElement, element) { return }
        lastElement = element
        onFocusChange(element, app)
    }
}
