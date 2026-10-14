import AppKit
import ApplicationServices

/// Calls `onFocusChange` when the cursor moves to another field, or the same field shows another chat.
/// Main signal: an Accessibility observer on the front app (same pattern as Input Source Pro); every
/// notification is handled, even for the same element, because leaving and coming back must re-check.
/// Fallback: a 0.4 s check of a cheap "place" (element + window title + WhatsApp chat name) for apps whose
/// observer stays silent, such as a chat change inside WhatsApp that keeps the same composer field.
/// Spotlight takes the keyboard without becoming the front app, so its own focus is checked first while it is open.
final class FocusWatcher {
    var onFocusChange: (AXUIElement, NSRunningApplication) -> Void = { _, _ in }

    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var lastElement: AXUIElement?
    private var lastPlace = ""
    private var whatsAppHeader: AXUIElement?
    private var timer: Timer?
    private var activationToken: NSObjectProtocol?
    private var spotlightObserver: AXObserver?
    private var spotlightApp: NSRunningApplication?
    private var spotlightOpen = false

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
        detachSpotlight()
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
        guard AXIsProcessTrusted() else { return }
        let target: (AXUIElement, NSRunningApplication)
        if let spotlight = spotlightFocus() {
            target = spotlight
        } else {
            guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
                  let element = AX.focusedElement(pid: app.processIdentifier) else { return }
            target = (element, app)
        }
        let (element, app) = target
        let place = place(of: element, app: app)
        if !force, let lastElement, CFEqual(lastElement, element), place == lastPlace { return }
        lastElement = element
        lastPlace = place
        onFocusChange(element, app)
    }

    /// Spotlight's search field while its panel is open. Probed live 2026-10-14 (macOS 27): the panel's process
    /// sends AXApplicationShown when it opens and AXApplicationHidden when it closes, and keeps reporting its
    /// text field as focused after it closes. So "open" comes only from those two events, and while it is
    /// closed this costs one property read per check.
    private func spotlightFocus() -> (AXUIElement, NSRunningApplication)? {
        if spotlightApp?.isTerminated ?? true {
            detachSpotlight()
            guard let app = FieldInfo.spotlightApps.lazy
                    .compactMap({ NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }).first else { return nil }
            attachSpotlight(app)
        }
        guard spotlightOpen, let app = spotlightApp, let element = AX.focusedElement(pid: app.processIdentifier),
              FieldInfo.textRoles.contains(AX.string(element, kAXRoleAttribute)) else { return nil }
        return (element, app)
    }

    private func attachSpotlight(_ app: NSRunningApplication) {
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<FocusWatcher>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated {
                if name == kAXApplicationShownNotification { watcher.spotlightOpen = true }
                if name == kAXApplicationHiddenNotification { watcher.spotlightOpen = false }
                watcher.check(force: true)
            }
        }
        spotlightApp = app   // remembered even if the observer fails, so the lookup is not repeated every check
        guard AXObserverCreate(app.processIdentifier, callback, &created) == .success, let created else { return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXApplicationShownNotification, kAXApplicationHiddenNotification] {
            AXObserverAddNotification(created, appElement, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        spotlightObserver = created
    }

    private func detachSpotlight() {
        if let spotlightObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(spotlightObserver), .defaultMode)
        }
        spotlightObserver = nil
        spotlightApp = nil
        spotlightOpen = false
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
