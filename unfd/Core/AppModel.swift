import AppKit
import Carbon
import ApplicationServices
import Observation
import ServiceManagement

/// The app's brain: watches the cursor, decides the language, switches, remembers, counts.
@Observable
final class AppModel {
    // Panel switches (saved).
    var enabled: Bool { didSet { save(); if enabled { watcher.recheck() } } }
    var rules: Rules { didSet { save(); if rules.autoFix { autoFixer.load() } } }
    var westernDigits: Bool { didSet { save() } }
    var showIndicator: Bool { didSet { save() } }

    // What the panel shows.
    private(set) var currentLang: Lang? = InputSources.currentLang()
    private(set) var nowApp = ""
    private(set) var nowPlace = ""
    private(set) var nowLang: Lang?
    private(set) var nowReason: Reason?
    private(set) var correctionsToday = 0
    private(set) var midTextToday = 0
    private(set) var autoFixesToday = 0
    private(set) var undoneFixesToday = 0
    private(set) var trusted = AXIsProcessTrusted()
    private(set) var arabic123Enabled = InputSources.isArabic123Enabled()
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var memory: [String: Lang] = [:]
    private(set) var learner = Learner()

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let watcher = FocusWatcher()
    @ObservationIgnored private let hotKey = FixHotKey()
    @ObservationIgnored private var lastSwitchByApp = Date.distantPast
    @ObservationIgnored private var lastSelectedByApp: Lang?
    @ObservationIgnored private var lastLearnKey: String?
    @ObservationIgnored private var typedSinceFocus = 0
    @ObservationIgnored private var countersDay = ""
    @ObservationIgnored private var lastChatKey: String?
    @ObservationIgnored private var lastPlace: String?
    @ObservationIgnored private var manualPlace: String?
    @ObservationIgnored private var lastElement: ElementBox?
    @ObservationIgnored private let indicator = CaretIndicator()
    @ObservationIgnored private var trustTimer: Timer?
    @ObservationIgnored private var readGeneration = 0
    @ObservationIgnored private var focusIsTextEntry = false
    @ObservationIgnored private var slash = SlashMode()
    @ObservationIgnored private var beforeSlash: (Lang?, Reason?)
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private let autoFixer = AutoFixer()
    @ObservationIgnored private var autoFixAllowed = false

    init() {
        enabled = defaults.object(forKey: "enabled") as? Bool ?? true
        rules = Rules(linkFields: defaults.object(forKey: "rule.links") as? Bool ?? true,
                      systemFields: defaults.object(forKey: "rule.system") as? Bool ?? true,
                      textDecides: defaults.object(forKey: "rule.text") as? Bool ?? true,
                      chatMemory: defaults.object(forKey: "rule.memory") as? Bool ?? true,
                      slashCommands: defaults.object(forKey: "rule.slash") as? Bool ?? true,
                      learn: defaults.object(forKey: "rule.learn") as? Bool ?? true,
                      autoFix: defaults.object(forKey: "rule.autofix") as? Bool ?? false)
        westernDigits = defaults.object(forKey: "westernDigits") as? Bool ?? true
        showIndicator = defaults.object(forKey: "showIndicator") as? Bool ?? false   // macOS shows its own tag after a switch; ours is a backup
        if let data = defaults.data(forKey: "memory"), let saved = try? JSONDecoder().decode([String: Lang].self, from: data) {
            memory = Self.chatOnly(saved)   // older versions also saved window-title entries; those are dropped
        }
        if let data = defaults.data(forKey: "learned"), let saved = try? JSONDecoder().decode(Learner.self, from: data) {
            learner = saved
        }
        countersDay = defaults.string(forKey: "manual.day") ?? ""
        if countersDay == Self.today {
            // The old v0.2 key "manual.count" still loads: those presses count as corrections.
            correctionsToday = defaults.object(forKey: "manual.corrections") as? Int ?? defaults.integer(forKey: "manual.count")
            midTextToday = defaults.integer(forKey: "manual.mid")
            autoFixesToday = defaults.integer(forKey: "autofix.count")
            undoneFixesToday = defaults.integer(forKey: "autofix.undone")
        }
        if rules.autoFix { autoFixer.load() }
        autoFixer.onFixed = { [weak self] lang in
            guard let self else { return }
            switchTo(lang, reason: .autoFix)
            manualPlace = lastPlace   // the fixed language holds for this place, like the fix button
            bumpDay(); autoFixesToday += 1; save()
        }
        autoFixer.onUndone = { [weak self] lang in
            guard let self else { return }
            switchTo(lang, reason: .undoFix)
            manualPlace = lastPlace
            bumpDay(); undoneFixesToday += 1; save()
        }

        watcher.onFocusChange = { [weak self] element, app in self?.focusChanged(element, app) }
        hotKey.onFix = { [weak self] lang in
            guard let self else { return }
            switchTo(lang, reason: .fix)
            manualPlace = lastPlace   // the fixed language holds for this place, like a manual press
        }
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
        #if DEBUG
        if defaults.string(forKey: "snapshotDir") != nil { return }   // snapshot runs draw only; never switch his keyboard
        #endif
        if trusted { startWatching(); return }
        // First run: show the system permission dialog once, without waiting for him to open the panel.
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if !isTestHost, !defaults.bool(forKey: "promptedOnce") {
            defaults.set(true, forKey: "promptedOnce")
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted() else { return }
                self.trustTimer?.invalidate()
                self.trustTimer = nil
                self.trusted = true
                self.startWatching()
            }
        }
    }

    private func startWatching() {
        watcher.start()
        // Key presses, only to spot a "/" at a word start and the key that ends the command. Listen-only:
        // nothing is blocked, changed or saved. Covered by the Accessibility permission.
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.keyPressed(event) }
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

    func clearLearned() {
        learner.clear()
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
            guard field.isTextEntry else {
                // Not a text field: a manual switch now must not be saved to the last chat.
                await MainActor.run { [weak self] in
                    self?.lastChatKey = nil
                    self?.lastLearnKey = nil
                    self?.focusIsTextEntry = false
                    self?.slash.reset()
                    self?.autoFixAllowed = false
                    self?.autoFixer.fieldChanged()
                }
                return
            }
            let context = ContextReader.read(box.element, bundleID: bundleID)
            let detected = ScriptDetector.detect(context.texts)
            let fieldText = ScriptDetector.detectOwn(context.field.ownText)
            await MainActor.run { [weak self] in
                guard let self, generation == self.readGeneration else { return }
                self.apply(context, detected: detected, fieldText: fieldText, appName: appName, element: box)
            }
        }
    }

    /// Chat memory holds WhatsApp chats only. Drops entries from other apps and the "WhatsApp" window title,
    /// which older versions saved when no chat name was read. Bidi marks around a name do not count.
    nonisolated static func chatOnly(_ memory: [String: Lang]) -> [String: Lang] {
        let prefix = "net.whatsapp.WhatsApp|"
        let marks: Set<Unicode.Scalar> = ["\u{200E}", "\u{200F}", "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
                                          "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}"]
        return memory.filter { key, _ in
            guard key.hasPrefix(prefix) else { return false }
            var scalars = String.UnicodeScalarView()
            scalars.append(contentsOf: key.dropFirst(prefix.count).unicodeScalars.filter { !marks.contains($0) })
            let name = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
            return !name.isEmpty && name != "WhatsApp"
        }
    }

    private func apply(_ context: FieldContext, detected: Lang?, fieldText: Lang?, appName: String, element: ElementBox) {
        focusIsTextEntry = true
        let isLink = context.field.isLinkField
        let isSystem = context.field.isSystemField
        lastChatKey = !isLink && !isSystem && context.isChat ? context.chatKey : nil   // memory is for WhatsApp chats only
        lastElement = element
        // A manual switch holds for this place (this field type, this chat or window) until he moves elsewhere,
        // so a repeated focus event can never flip his choice back while he types.
        let place = isLink ? "\(context.field.bundleID)|link" : isSystem ? "\(context.field.bundleID)|system" : context.chatKey
        lastLearnKey = Learner.key(for: context.field, isChat: context.readsMessages)   // chats follow their messages, never learned
        if place != lastPlace { manualPlace = nil; lastPlace = place; slash.reset(); typedSinceFocus = 0; autoFixer.fieldChanged() }
        // Never in password, link and system fields, nor in terminals (Secure Keyboard Entry is checked at each word).
        autoFixAllowed = !isLink && !isSystem && !AutoFixer.terminals.contains(context.field.bundleID)
        if manualPlace == place || slash.isActive { return }
        nowApp = appName
        nowPlace = isLink ? "خانة رابط" : isSystem ? "" : context.isChat ? context.chatName : ""
        guard let (lang, reason) = Decider.decide(isLinkField: isLink, isSystemField: isSystem, isChat: context.readsMessages,
                                                  systemLang: Lang.system(),
                                                  fieldText: fieldText,
                                                  remembered: context.isChat ? memory[context.chatKey] : nil,
                                                  learned: lastLearnKey.flatMap { learner.learned(for: $0) },
                                                  detected: detected, rules: rules) else {
            nowLang = nil; nowReason = nil
            return
        }
        switchTo(lang, reason: reason)
    }

    private func switchTo(_ lang: Lang, reason: Reason) {
        nowLang = lang
        nowReason = reason
        let before = InputSources.currentLang()
        lastSwitchByApp = Date()
        lastSelectedByApp = lang
        guard InputSources.select(lang, westernDigits: westernDigits) else { return }
        currentLang = lang
        if showIndicator, before != lang, let element = lastElement?.element { indicator.show(lang, at: element) }
    }

    /// Slash commands: English after a "/" at a word start, the earlier language back on Space, Return, Tab or Escape.
    private func keyPressed(_ event: NSEvent) {
        guard enabled, focusIsTextEntry, !AutoFixer.isOwn(event) else { return }
        if rules.autoFix, !slash.isActive {
            autoFixer.keyPressed(event, allowed: autoFixAllowed, fieldLang: nowLang)
        }
        let key: SlashMode.Key
        if event.type != .keyDown || !event.modifierFlags.intersection([.command, .control]).isEmpty {
            key = .other
        } else {
            switch Int(event.keyCode) {
            case kVK_Space: key = .space
            case kVK_Return, kVK_ANSI_KeypadEnter: key = .enter
            case kVK_Tab: key = .tab
            case kVK_Escape: key = .escape
            case kVK_Delete: key = .delete
            default:
                let typed = event.characters ?? ""
                key = typed.unicodeScalars.contains { (0xF700...0xF8FF).contains($0.value) } ? .other : .text(typed)   // arrows, F-keys
            }
        }
        // Counts typed characters per place (never which ones), so a press of the language key can be told apart:
        // right after focus = a correction; after typing = a switch in the middle of text.
        // Return starts over (WhatsApp and Claude send on Return); the empty-field check still guards multi-line text.
        if case .text = key { typedSinceFocus += 1 } else if key == .enter { typedSinceFocus = 0 }
        guard rules.slashCommands else { return }
        switch slash.press(key, current: currentLang) {
        case .toEnglish?:
            autoFixer.cursorMoved()   // the "/" is not part of a word
            beforeSlash = (nowLang, nowReason)
            if currentLang != .en { switchTo(.en, reason: .slash) }
        case .restore(let lang)?:
            // Only undo our own switch: if he changed the language during the command, leave his choice.
            if lang != .en, currentLang == .en { switchTo(lang, reason: .slash) }
            (nowLang, nowReason) = beforeSlash
        case nil:
            break
        }
    }

    /// Any keyboard change. If the app did not cause it, he pressed the switch key. A press before typing anything
    /// corrects the app (counted, remembered for the WhatsApp chat, learned for the field kind); a press in the middle of
    /// text only holds for this place and teaches nothing.
    private func inputSourceChanged() {
        let lang = InputSources.currentLang()
        currentLang = lang
        guard let lang else { return }
        // The app's own switch: same language, within 1 s. A different language in that second is his correction.
        if lang == lastSelectedByApp, Date().timeIntervalSince(lastSwitchByApp) <= 1 { return }
        manualPlace = lastPlace   // holds at once, so the 0.4 s re-check never flips it back
        slash.reset()
        autoFixer.cursorMoved()   // keys pressed before the layout change would read wrong now
        let place = lastPlace, chatKey = lastChatKey, learnKey = lastLearnKey, typed = typedSinceFocus
        let box = lastElement
        // One field-value read per manual press (never per key), off the main thread.
        Task.detached(priority: .userInitiated) {
            let value = box.flatMap { AX.value($0.element, kAXValueAttribute) as? String }
            let kind = Learner.classify(typedSinceFocus: typed, fieldValue: value)
            await MainActor.run { [weak self] in
                self?.finishPress(kind, lang: lang, place: place, chatKey: chatKey, learnKey: learnKey)
            }
        }
    }

    private func bumpDay() {
        if countersDay != Self.today {
            countersDay = Self.today; correctionsToday = 0; midTextToday = 0; autoFixesToday = 0; undoneFixesToday = 0
        }
    }

    private func finishPress(_ kind: PressKind, lang: Lang, place: String?, chatKey: String?, learnKey: String?) {
        guard place == lastPlace else { return }   // he moved on while the field was read
        bumpDay()
        switch kind {
        case .correction:
            correctionsToday += 1
            if rules.chatMemory, let chatKey { memory[chatKey] = lang; nowLang = lang; nowReason = .memory }
            if rules.learn, let learnKey { learner.record(lang, for: learnKey) }
        case .midText:
            midTextToday += 1
        }
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
        defaults.set(rules.systemFields, forKey: "rule.system")
        defaults.set(rules.textDecides, forKey: "rule.text")
        defaults.set(rules.chatMemory, forKey: "rule.memory")
        defaults.set(rules.slashCommands, forKey: "rule.slash")
        defaults.set(rules.learn, forKey: "rule.learn")
        defaults.set(rules.autoFix, forKey: "rule.autofix")
        defaults.set(westernDigits, forKey: "westernDigits")
        defaults.set(showIndicator, forKey: "showIndicator")
        defaults.set(try? JSONEncoder().encode(memory), forKey: "memory")
        defaults.set(try? JSONEncoder().encode(learner), forKey: "learned")
        defaults.set(countersDay.isEmpty ? Self.today : countersDay, forKey: "manual.day")
        defaults.set(correctionsToday, forKey: "manual.corrections")
        defaults.set(midTextToday, forKey: "manual.mid")
        defaults.set(autoFixesToday, forKey: "autofix.count")
        defaults.set(undoneFixesToday, forKey: "autofix.undone")
    }
}

/// AXUIElement is a thread-safe CF reference; this box lets it cross to the background reader.
nonisolated struct ElementBox: @unchecked Sendable {
    let element: AXUIElement
}
