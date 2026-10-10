import Carbon
import Foundation

/// Apple's keyboard layout ids the app uses.
nonisolated enum InputSourceIDs {
    static let abc = "com.apple.keylayout.ABC"
    static let arabic = "com.apple.keylayout.Arabic"
    /// "Arabic – 123": the same letters as "Arabic", with 1234567890 on the number row.
    static let arabic123 = "com.apple.keylayout.Arabic-NorthAfrica"

    /// Any installed layout by id, enabled or not.
    static func find(_ id: String, includeAllInstalled: Bool = true) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, includeAllInstalled)?.takeRetainedValue() as? [TISInputSource] else { return nil }
        return list.first
    }

    static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    static func languages(_ source: TISInputSource) -> [String] {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return [] }
        return (Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as? [String]) ?? []
    }

    static func enabledKeyboardLayouts() -> [TISInputSource] {
        let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String] as CFDictionary
        return (TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource]) ?? []
    }
}

/// Reads and changes the current keyboard language.
enum InputSources {
    static func currentLang() -> Lang? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return lang(of: source)
    }

    static func lang(of source: TISInputSource) -> Lang? {
        let langs = InputSourceIDs.languages(source)
        if langs.first == "ar" { return .ar }
        if let id = InputSourceIDs.string(source, kTISPropertyInputSourceID), id.contains("Arabic") { return .ar }
        return .en
    }

    static func isArabic123Enabled() -> Bool {
        InputSourceIDs.enabledKeyboardLayouts().contains {
            InputSourceIDs.string($0, kTISPropertyInputSourceID) == InputSourceIDs.arabic123
        }
    }

    /// Adds "Arabic – 123" to his input sources. Only called from the panel button he presses.
    @discardableResult
    static func enableArabic123() -> Bool {
        guard let source = InputSourceIDs.find(InputSourceIDs.arabic123) else { return false }
        return TISEnableInputSource(source) == noErr
    }

    /// The layout to select for a language. Arabic prefers "Arabic – 123" when `westernDigits` is on.
    static func target(for lang: Lang, westernDigits: Bool) -> TISInputSource? {
        let enabled = InputSourceIDs.enabledKeyboardLayouts()
        func id(_ s: TISInputSource) -> String { InputSourceIDs.string(s, kTISPropertyInputSourceID) ?? "" }
        switch lang {
        case .en:
            return enabled.first { id($0) == InputSourceIDs.abc }
                ?? enabled.first { self.lang(of: $0) == .en }
        case .ar:
            if westernDigits, let s = enabled.first(where: { id($0) == InputSourceIDs.arabic123 }) { return s }
            return enabled.first { id($0) == InputSourceIDs.arabic }
                ?? enabled.first { self.lang(of: $0) == .ar }
        }
    }

    /// Selects the layout. Returns false when nothing matching is enabled.
    @discardableResult
    static func select(_ lang: Lang, westernDigits: Bool) -> Bool {
        guard let source = target(for: lang, westernDigits: westernDigits) else { return false }
        if let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           InputSourceIDs.string(current, kTISPropertyInputSourceID) == InputSourceIDs.string(source, kTISPropertyInputSourceID) {
            return true
        }
        return TISSelectInputSource(source) == noErr
    }
}
