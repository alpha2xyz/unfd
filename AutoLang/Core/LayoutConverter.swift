import Carbon
import Foundation

/// Turns text typed in the wrong layout into the right one, key by key.
/// The map is read from the Mac's own layouts (UCKeyTranslate), so it always matches what the keys type.
nonisolated struct LayoutConverter: Sendable {
    private let toArabic: [String: String]
    private let toEnglish: [String: String]
    private static let arabicDigits: [String: String] = Dictionary(
        uniqueKeysWithValues: zip("٠١٢٣٤٥٦٧٨٩".map(String.init), "0123456789".map(String.init)))

    init?(englishLayoutID: String = InputSourceIDs.abc, arabicLayoutID: String = InputSourceIDs.arabic123) {
        guard let english = Self.keyMap(layoutID: englishLayoutID),
              let arabic = Self.keyMap(layoutID: arabicLayoutID) else { return nil }
        var toArabic: [String: String] = [:], toEnglish: [String: String] = [:]
        for (key, latin) in english {
            guard let arabicChar = arabic[key], arabicChar != latin else { continue }
            if toArabic[latin] == nil { toArabic[latin] = arabicChar }
            if toEnglish[arabicChar] == nil { toEnglish[arabicChar] = latin }
        }
        for (indic, western) in Self.arabicDigits { toEnglish[indic] = western }
        self.toArabic = toArabic
        self.toEnglish = toEnglish
    }

    /// Converts toward the language the text is NOT in, and returns that language.
    func fix(_ text: String) -> (text: String, lang: Lang) {
        let counts = ScriptDetector.letterCounts(text)
        let hasIndicDigits = text.contains { Self.arabicDigits[String($0)] != nil }
        let target: Lang = (counts.arabic > counts.latin || (counts.arabic == 0 && counts.latin == 0 && hasIndicDigits)) ? .en : .ar
        return (convert(text, using: target == .ar ? toArabic : toEnglish), target)
    }

    func convert(_ text: String, to lang: Lang) -> String {
        convert(text, using: lang == .ar ? toArabic : toEnglish)
    }

    /// Greedy: a key can type two letters (for example لا), so try two characters before one.
    private func convert(_ text: String, using map: [String: String]) -> String {
        let chars = Array(text)
        var out = "", i = 0
        while i < chars.count {
            if i + 1 < chars.count, let two = map[String(chars[i...i + 1])] {
                out += two; i += 2
            } else {
                out += map[String(chars[i])] ?? String(chars[i]); i += 1
            }
        }
        return out
    }

    /// Key (code + shift) → the text that layout types for it.
    private static func keyMap(layoutID: String) -> [Int: String]? {
        guard let source = InputSourceIDs.find(layoutID),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var map: [Int: String] = [:]
        data.withUnsafeBytes { buffer in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
            for code in 0..<51 where code != kVK_Tab && code != kVK_Space {
                for shift in [false, true] {
                    var dead: UInt32 = 0, length = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    let modifiers = UInt32(shift ? (shiftKey >> 8) & 0xFF : 0)
                    let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), modifiers,
                                                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                                &dead, 4, &length, &chars)
                    guard status == noErr, length > 0 else { continue }
                    let text = String(utf16CodeUnits: chars, count: length)
                    if text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) {
                        map[code * 2 + (shift ? 1 : 0)] = text
                    }
                }
            }
        }
        return map.isEmpty ? nil : map
    }
}
