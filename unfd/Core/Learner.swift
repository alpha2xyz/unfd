import Foundation

/// What a manual press of the language key was.
nonisolated enum PressKind: Sendable, Equatable {
    /// He changed the app's choice before typing anything here: a real correction.
    case correction
    /// He switched in the middle of typing (Arabic sentence, then the English word "otp"): teaches nothing.
    case midText
}

/// Learns his language per kind of field from his corrections. Stores languages and keys only, never typed text.
/// A place counts as learned when his last 3 corrections there are the same language (the last 5 are kept).
nonisolated struct Learner: Sendable, Codable, Equatable {
    static let keep = 5
    static let needed = 3

    private(set) var corrections: [String: [Lang]] = [:]

    /// A press is a correction only when nothing was typed in this place and the field is still empty
    /// (or unreadable). Anything else is a switch in the middle of text.
    static func classify(typedSinceFocus: Int, fieldValue: String?) -> PressKind {
        guard typedSinceFocus == 0 else { return .midText }
        let value = fieldValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == nil || value!.isEmpty ? .correction : .midText
    }

    /// Browsers: every website is the same text field under one bundle ID, so per-browser learning would be wrong.
    static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.canary",
        "company.thebrowser.Browser", "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser",
        "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]

    /// The learning key for a field, or nil where nothing is learned: link and system fields, chats the
    /// WhatsApp reader recognised (they have their own memory), and browsers.
    static func key(for field: FieldInfo, isChat: Bool) -> String? {
        if field.isLinkField || field.isSystemField || isChat || browsers.contains(field.bundleID) { return nil }
        return "\(field.bundleID)|\(field.role)|\(field.subrole)"
    }

    mutating func record(_ lang: Lang, for key: String) {
        corrections[key, default: []].append(lang)
        if corrections[key]!.count > Self.keep { corrections[key]!.removeFirst(corrections[key]!.count - Self.keep) }
    }

    /// X only when the last 3 recorded corrections are all X.
    func learned(for key: String) -> Lang? {
        guard let last = corrections[key]?.suffix(Self.needed), last.count == Self.needed,
              let first = last.first, last.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    mutating func clear() { corrections = [:] }

    /// Places that currently have a learned language.
    var count: Int { corrections.keys.filter { learned(for: $0) != nil }.count }
}
