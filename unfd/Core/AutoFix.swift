import Foundation

/// Frequency word lists (word → rank, 0 = most common). Loaded once when auto-fix is on.
nonisolated struct WordLists: Sendable {
    var arabic: [String: Int]
    var english: [String: Int]

    /// One word per line, most common first (the bundled `Words/ar.txt` and `Words/en.txt`).
    static func parse(_ text: String) -> [String: Int] {
        var ranks: [String: Int] = [:]
        var rank = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let word = line.trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty, ranks[word] == nil else { continue }
            ranks[word] = rank
            rank += 1
        }
        return ranks
    }
}

/// The current word as key presses (never characters), so it can be read in either layout.
/// Cleared on anything that moves the cursor: focus change, click, arrows, shortcuts, an empty-buffer backspace.
nonisolated struct WordBuffer: Sendable, Equatable {
    struct Key: Equatable, Sendable {
        var code: Int
        var shift: Bool
        var mapIndex: Int { code * 2 + (shift ? 1 : 0) }
    }

    private(set) var keys: [Key] = []
    /// The layout the keys were typed in. A key in another layout starts a new word: the fast second word of
    /// «hgsghl ugd;l» must not be read through the layout the first fix switched to.
    private(set) var layoutID: String?
    var isEmpty: Bool { keys.isEmpty }

    mutating func append(_ key: Key, layoutID: String) {
        if layoutID != self.layoutID { keys = []; self.layoutID = layoutID }
        keys.append(key)
    }

    /// Backspace removes the last key; on an empty buffer the cursor position is unknown, so the caller resets.
    mutating func backspace() { if !keys.isEmpty { keys.removeLast() } }

    mutating func clear() { keys = []; layoutID = nil }

    /// The text these keys type in a layout (`map` from `LayoutConverter.keyMap`). Nil when a key is unknown there.
    func text(in map: [Int: String]) -> String? {
        var out = ""
        for key in keys {
            guard let piece = map[key.mapIndex] else { return nil }
            out += piece
        }
        return out
    }
}

/// Decides whether a finished word was typed in the wrong layout. Pure: the lists and spell checks are injected.
nonisolated struct AutoFixDetector: Sendable {
    struct Context: Sendable, Equatable {
        /// The language the previous word in this field was fixed to, if any.
        var previousFixed: Lang?
        /// The language unfd chose for this field.
        var fieldLang: Lang?
    }

    struct Fix: Sendable, Equatable {
        var text: String   // the whole word in the right layout, trailing punctuation included
        var lang: Lang
    }

    var words: WordLists
    var spelledArabic: @Sendable (String) -> Bool
    var spelledEnglish: @Sendable (String) -> Bool
    /// Only the most common English words count as "an English word was meant" (feasibility: top 30k).
    var englishTargetRank = 30_000

    /// `typed` is what the keys showed on screen, `converted` the same keys in the other layout.
    func check(typed: String, converted: String, context: Context, skip: Set<String> = []) -> Fix? {
        guard !skip.contains(typed) else { return nil }
        // The fixed word must be letters only; the typed one may hold ";" or "," (ك and و on the English layout).
        guard let convertedStem = Self.stem(converted), let typedStem = Self.trimmed(typed) else { return nil }
        guard let target = Self.script(of: convertedStem), Self.script(of: typedStem) == target.other else { return nil }
        let length = convertedStem.count
        guard length >= 2 else { return nil }
        let inContext = context.previousFixed == target || context.fieldLang == target
        // 2-letter words: too many are words in both layouts (في→td, هو→im); only context can tell.
        if length == 2, !inContext { return nil }
        switch target {
        case .ar:
            guard words.arabic[convertedStem] != nil else { return nil }
            // Not with context: whatever is a plain English word stays (ma, im, srt).
            let english = typedStem.lowercased()
            if !inContext, words.english[english] != nil || spelledEnglish(english) { return nil }
        case .en:
            let english = convertedStem.lowercased()
            guard let rank = words.english[english], rank < englishTargetRank else { return nil }
            // A real Arabic word stays, even a rare one (لهب, وخز): the list first, then the spell checker.
            if words.arabic[typedStem] != nil { return nil }
            if !inContext, spelledArabic(typedStem) { return nil }
        }
        return Fix(text: target == .en ? converted.lowercasedIfLatin : converted, lang: target)
    }

    /// Letters only, trailing punctuation dropped ("hello," → "hello"); nil when something else is inside.
    static func stem(_ word: String) -> String? {
        guard let trimmed = trimmed(word), trimmed.allSatisfy(\.isLetter) else { return nil }
        return trimmed
    }

    /// Trailing punctuation dropped; nil when nothing is left.
    static func trimmed(_ word: String) -> String? {
        var chars = Array(word)
        while let last = chars.last, !last.isLetter { chars.removeLast() }
        return chars.isEmpty ? nil : String(chars)
    }

    static func script(of stem: String) -> Lang? {
        let counts = ScriptDetector.letterCounts(stem)
        if counts.arabic > 0, counts.latin == 0 { return .ar }
        if counts.latin > 0, counts.arabic == 0 { return .en }
        return nil
    }
}

nonisolated private extension Lang {
    var other: Lang { self == .ar ? .en : .ar }
}

nonisolated private extension String {
    /// Shift held by mistake must not stay in the fixed English word.
    var lowercasedIfLatin: String { lowercased() }
}

/// ⌘Z right after a fix (within 5 s, before any other key) puts the original back.
nonisolated struct AutoFixUndo: Sendable, Equatable {
    struct Pending: Sendable, Equatable {
        var original: String
        var fixed: String
        var originalLang: Lang
        var fixedLang: Lang
        var at: Date
    }

    static let window: TimeInterval = 5
    private(set) var pending: Pending?

    mutating func fixed(_ pending: Pending) { self.pending = pending }

    /// One key press. Returns the fix to undo on ⌘Z inside the window; any other key closes the window.
    mutating func keyPressed(isUndo: Bool, now: Date = Date()) -> Pending? {
        guard let pending else { return nil }
        self.pending = nil
        guard isUndo, now.timeIntervalSince(pending.at) <= Self.window else { return nil }
        return pending
    }

    mutating func clear() { pending = nil }
}
