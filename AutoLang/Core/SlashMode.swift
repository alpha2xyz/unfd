import Foundation

/// Slash commands (Claude, terminals, Slack): a "/" at the start of a word switches to English, because commands
/// are English; Space, Return, Tab or Escape ends the command and brings back the language from before the "/".
/// "10/2026" never starts it: that "/" follows a digit, not a word start. Pure state, so it can be tested.
nonisolated struct SlashMode: Sendable {
    enum Key: Equatable, Sendable { case text(String), space, enter, tab, escape, delete, other }
    enum Action: Equatable, Sendable { case toEnglish, restore(Lang) }

    /// The language from before the "/", while a command is being typed.
    private(set) var before: Lang?
    private var typedSinceSlash = 0
    private var atWordStart = true

    var isActive: Bool { before != nil }

    /// One key press (`.other` for arrows, shortcuts and clicks). `current` is the keyboard language now.
    mutating func press(_ key: Key, current: Lang?) -> Action? {
        if let before {
            switch key {
            case .space, .enter, .tab, .escape:
                reset(); return .restore(before)
            case .delete:
                // Deleting the "/" itself cancels the command.
                if typedSinceSlash == 0 { reset(); return .restore(before) }
                typedSinceSlash -= 1; return nil
            case .text:
                typedSinceSlash += 1; return nil
            case .other:
                return nil
            }
        }
        switch key {
        case .text("/") where atWordStart:
            before = current ?? .en
            typedSinceSlash = 0
            atWordStart = false
            return .toEnglish
        case .text(let typed):
            atWordStart = !typed.isEmpty && typed.allSatisfy(\.isWhitespace)
        case .space, .enter, .tab, .delete, .other:
            atWordStart = true   // after a cursor move or a deletion the previous character is unknown: allow
        case .escape:
            break
        }
        return nil
    }

    /// Focus moved to another place: drop the command without switching (the new place decides).
    mutating func reset() {
        before = nil
        typedSinceSlash = 0
        atWordStart = true
    }
}
