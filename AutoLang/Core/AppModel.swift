import AppKit
import ApplicationServices
import Observation
import ServiceManagement

/// The app's brain: watches the cursor, decides the language, switches, remembers, counts.
@Observable
final class AppModel {
    // Panel switches (saved).
    var enabled: Bool { didSet { save(); if enabled { watcher.recheck() } } }
    var rules: Rules { didSet { save() } }
    var westernDigits: Bool { didSet { save() } }

    // What the panel shows.
    private(set) var currentLang: Lang? = InputSources.currentLang()
    private(set) var nowApp = ""
    private(set) var nowPlace = ""
    private(set) var nowLang: Lang?
    private(set) var nowReason: Reason?
    private(set) var manualToday = 0
    private(set) var trusted = AXIsProcessTrusted()
    private(set) var arabic123Enabled = InputSources.isArabic123Enabled()
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var memory: [String: Lang] = [:]

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let watcher = FocusWatcher()
    @ObservationIgnored private let hotKey = FixHotKey()
    @ObservationIgnored private var lastSwitchByApp = Date.distantPast
    @ObservationIgnored private var lastChatKey: String?
    @ObservationIgnored private var trustTimer: Timer?
    @ObservationIgnored private var readGeneration = 0

    init() {
        enabled = defaults.object(forKey: "enabled") as? Bool ?? true
        rules = Rules(linkFields: defaults.object(forKey: "rule.links") as? Bool ?? true,
                      textDecides: defaults.object(forKey: "rule.text") as? Bool ?? true,
                      chatMemory: defaults.object(forKey: "rule.memory") as? Bool ?? true)
        westernDigits = defaults.object(forKey: "westernDigits") as? Bool ?? true
        if let data = defaults.data(forKey: "memory"), let saved = try? JSONDecoder().decode([String: Lang].self, from: data) {
            memory = saved
        }
        manualToday = defaults.string(forKey: "manual.day") == Self.today ? defaults.integer(forKey: "manual.count") : 0

        watcher.onFocusChange = { [weak self] element, app in self?.focusChanged(element, app) }
        hotKey.onFix = { [weak self] lang in self?.switchTo(lang, reason: .fix) }
        hotKey.register()
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.inputSourceChanged() }
        }
        startWhenTrusted()
    }

    // MARK: Permission

    func askForPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startWhenTrusted() {
        trusted = AXIsProcessTrusted()
        if trusted { watcher.start(); return }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted() else { return }
                self.trustTimer?.invalidate()
                self.trustTimer = nil
                self.trusted = true
                self.watcher.start()
            }
        }
    }

    // MARK: Panel actions

    func enableArabic123() {
        InputSources.enableArabic123()
        arabic123Enabled = InputSources.isArabic123Enabled()
    }

    func clearMemory() {
        memory = [:]
        save()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func refresh() {
        currentLang = InputSources.currentLang()
        arabic123Enabled = InputSources.isArabic123Enabled()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        trusted = AXIsProcessTrusted()
    }

    // MARK: Focus → decision → switch

    private func focusChanged(_ element: AXUIElement, _ app: NSRunningApplication) {
        guard enabled else { return }
        let bundleID = app.bundleIdentifier ?? ""
        let appName = app.localizedName ?? bundleID
        readGeneration += 1
        let generation = readGeneration
        let box = ElementBox(element: element)
        Task.detached(priority: .userInitiated) {
            let field = ContextReader.fieldInfo(box.element, bundleID: bundleID)
            guard field.isTextEntry else { return }
            let context = ContextReader.read(box.element, bundleID: bundleID)
            let detected = ScriptDetector.detect(context.texts)
            await MainActor.run { [weak self] in
                guard let self, generation == self.readGeneration else { return }
                self.apply(context, detected: detected, appName: appName)
            }
        }
    }

    private func apply(_ context: FieldContext, detected: Lang?, appName: String) {
        let isLink = context.field.isLinkField
        lastChatKey = isLink ? nil : context.chatKey
        nowApp = appName
        nowPlace = isLink ? "خانة رابط" : context.chatName
        guard let (lang, reason) = Decider.decide(isLinkField: isLink, remembered: memory[context.chatKey],
                                                  detected: detected, rules: rules) else {
            nowLang = nil; nowReason = nil
            return
        }
        switchTo(lang, reason: reason)
    }

    private func switchTo(_ lang: Lang, reason: Reason) {
        nowLang = lang
        nowReason = reason
        lastSwitchByApp = Date()
        if InputSources.select(lang, westernDigits: westernDigits) { currentLang = lang }
    }

    /// Any keyboard change. If the app did not cause it, he pressed the switch key: count it and remember it for this chat.
    private func inputSourceChanged() {
        let lang = InputSources.currentLang()
        currentLang = lang
        guard Date().timeIntervalSince(lastSwitchByApp) > 1, let lang else { return }
        if defaults.string(forKey: "manual.day") != Self.today { manualToday = 0 }
        manualToday += 1
        if rules.chatMemory, let key = lastChatKey { memory[key] = lang; nowLang = lang; nowReason = .memory }
        save()
    }

    // MARK: Saving

    private static var today: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    private func save() {
        defaults.set(enabled, forKey: "enabled")
        defaults.set(rules.linkFields, forKey: "rule.links")
        defaults.set(rules.textDecides, forKey: "rule.text")
        defaults.set(rules.chatMemory, forKey: "rule.memory")
        defaults.set(westernDigits, forKey: "westernDigits")
        defaults.set(try? JSONEncoder().encode(memory), forKey: "memory")
        defaults.set(Self.today, forKey: "manual.day")
        defaults.set(manualToday, forKey: "manual.count")
    }
}

/// AXUIElement is a thread-safe CF reference; this box lets it cross to the background reader.
nonisolated struct ElementBox: @unchecked Sendable {
    let element: AXUIElement
}
