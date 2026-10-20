import AppKit
import Carbon

/// Auto-fix while typing: watches the current word (keys only), and at Space replaces a word typed in the wrong
/// layout with the right one, then switches the keyboard. ⌘Z within 5 s puts it back. Nothing typed is stored.
final class AutoFixer {
    /// Marks the events this app posts, so its own monitors ignore them.
    static let eventTag: Int64 = 0x5546_4958   // "UFIX"
    static let terminals: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
                                         "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "com.mitchellh.ghostty"]

    var onFixed: (Lang) -> Void = { _ in }
    var onUndone: (Lang) -> Void = { _ in }

    private(set) var lists: WordLists?
    private var buffer = WordBuffer()
    private var undo = AutoFixUndo()
    private var skip: Set<String> = []
    private var lastFixedLang: Lang?
    private var maps: [String: [Int: String]] = [:]
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var loading = false

    /// Reads the bundled lists once, off the main thread (about 90k words).
    func load() {
        guard lists == nil, !loading else { return }
        loading = true
        Task.detached(priority: .utility) {
            func read(_ name: String) -> String {
                Bundle.main.url(forResource: name, withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            }
            let loaded = WordLists(arabic: WordLists.parse(read("ar")), english: WordLists.parse(read("en")))
            await MainActor.run { [weak self] in
                self?.lists = loaded
                self?.loading = false
            }
        }
    }

    /// Focus moved to another field: the word and the context belong to the old one.
    func fieldChanged() {
        buffer.clear()
        undo.clear()
        setTap(enabled: false)
        lastFixedLang = nil
    }

    func cursorMoved() { buffer.clear() }

    /// One key press from the listen-only monitor. `allowed` is false in link, password and system fields and in
    /// terminals; `fieldLang` is the language unfd chose for this field.
    func keyPressed(_ event: NSEvent, allowed: Bool, fieldLang: Lang?) {
        guard event.type == .keyDown else { cursorMoved(); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.shift, .capsLock, .numericPad])
        if !flags.isEmpty { cursorMoved(); return }   // ⌘, ⌃, ⌥, fn: a shortcut or a symbol
        let code = Int(event.keyCode)
        switch code {
        case kVK_Delete:
            if buffer.isEmpty { cursorMoved() } else { buffer.backspace() }
        case kVK_Space:
            finishWord(allowed: allowed, fieldLang: fieldLang, spaceEvent: event)
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab, kVK_Escape:
            buffer.clear()   // Return may have sent the message already; fixing afterwards would land in the next one
        case 0..<51:
            guard let layoutID = Self.currentLayoutID() else { cursorMoved(); return }
            buffer.append(.init(code: code, shift: event.modifierFlags.contains(.shift)), layoutID: layoutID)
        default:
            cursorMoved()   // arrows, F-keys, forward delete
        }
    }

    private func finishWord(allowed: Bool, fieldLang: Lang?, spaceEvent: NSEvent) {
        let keys = buffer
        buffer.clear()
        guard allowed, let lists, !keys.isEmpty, !IsSecureEventInputEnabled() else { return }
        guard let currentID = keys.layoutID, let current = InputSourceIDs.find(currentID) else { return }
        let currentLang = InputSources.lang(of: current) ?? .en
        let otherID = currentLang == .ar ? InputSourceIDs.abc
            : (InputSources.target(for: .ar, westernDigits: true).flatMap { InputSourceIDs.string($0, kTISPropertyInputSourceID) } ?? InputSourceIDs.arabic123)
        guard let typed = keys.text(in: map(currentID)), let converted = keys.text(in: map(otherID)) else { return }
        let detector = AutoFixDetector(words: lists, spelledArabic: { Self.spelled($0, "ar") }, spelledEnglish: { Self.spelled($0, "en") })
        let context = AutoFixDetector.Context(previousFixed: lastFixedLang, fieldLang: fieldLang)
        guard let fix = detector.check(typed: typed, converted: converted, context: context, skip: skip) else { return }
        // The Space has already landed (listen-only monitor): take back the word and the space, type the fixed word.
        Self.replace(count: typed.count + 1, with: fix.text + " ")
        lastFixedLang = fix.lang
        undo.fixed(.init(original: typed, fixed: fix.text, originalLang: currentLang, fixedLang: fix.lang, at: Date()))
        setTap(enabled: true)
        onFixed(fix.lang)
    }

    private static func currentLayoutID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return InputSourceIDs.string(source, kTISPropertyInputSourceID)
    }

    private func map(_ layoutID: String) -> [Int: String] {
        if let cached = maps[layoutID] { return cached }
        let built = LayoutConverter.keyMap(layoutID: layoutID) ?? [:]
        maps[layoutID] = built
        return built
    }

    nonisolated private static func spelled(_ word: String, _ language: String) -> Bool {
        MainActor.assumeIsolated {
            let range = NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                                            inSpellDocumentWithTag: 0, wordCount: nil)
            return range.location == NSNotFound
        }
    }

    // MARK: Replacing text

    private static func replace(count: Int, with text: String) {
        let source = CGEventSource(stateID: .privateState)
        for _ in 0..<count { press(UInt16(kVK_Delete), source: source) }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
            var units = Array(text.utf16)
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            event.setIntegerValueField(.eventSourceUserData, value: eventTag)
            event.post(tap: .cghidEventTap)
        }
    }

    private static func press(_ key: UInt16, source: CGEventSource?) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.setIntegerValueField(.eventSourceUserData, value: eventTag)
            event.post(tap: .cghidEventTap)
        }
    }

    static func isOwn(_ event: NSEvent) -> Bool {
        event.cgEvent?.getIntegerValueField(.eventSourceUserData) == eventTag
    }

    // MARK: ⌘Z

    /// Swallowing ⌘Z needs an active tap. It exists only once a fix happened and is enabled only during the 5 s window,
    /// so outside that window every key passes untouched and nothing runs.
    private func setTap(enabled: Bool) {
        if enabled, tap == nil {
            let callback: CGEventTapCallBack = { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                let box = EventBox(event: event)   // the tap runs on the main run loop
                let swallow = MainActor.assumeIsolated {
                    Unmanaged<AutoFixer>.fromOpaque(info).takeUnretainedValue().tapped(type, box.event)
                }
                return swallow ? nil : Unmanaged.passUnretained(event)
            }
            tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                    eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
                                    callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
            guard let tap else { return }
            tapSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        }
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: enabled)
    }

    /// True when the event must be swallowed (the ⌘Z that undid a fix).
    private func tapped(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if undo.pending != nil, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard type == .keyDown, event.getIntegerValueField(.eventSourceUserData) != Self.eventTag else { return false }
        let isUndo = event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_ANSI_Z)
            && event.flags.contains(.maskCommand) && !event.flags.contains(.maskShift) && !event.flags.contains(.maskAlternate)
        let pending = undo.keyPressed(isUndo: isUndo)
        setTap(enabled: false)
        guard let pending else { return false }
        Self.replace(count: pending.fixed.count + 1, with: pending.original + " ")
        skip.insert(pending.original)
        lastFixedLang = nil
        buffer.clear()
        onUndone(pending.originalLang)
        return true
    }
}

/// CGEvent is a CF object; this box lets the tap callback hand it to the main actor it already runs on.
nonisolated struct EventBox: @unchecked Sendable {
    let event: CGEvent
}
