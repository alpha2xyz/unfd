import Foundation

/// The two keyboard languages the app switches between.
nonisolated enum Lang: String, Codable, Sendable, CaseIterable {
    case ar, en

    var menuBarLabel: String { self == .ar ? "ع" : "EN" }
    var arabicName: String { self == .ar ? "عربي" : "إنجليزي" }
}

/// Why the app picked a language. Shown in the panel's "now" line.
nonisolated enum Reason: Sendable, Equatable {
    case linkField
    case memory
    case text(Lang)
    case fix

    var arabic: String {
        switch self {
        case .linkField: "خانة رابط أو عنوان"
        case .memory: "اخترتها بيدك لهذي المحادثة"
        case .text(.ar): "آخر الكلام بالعربي"
        case .text(.en): "آخر الكلام بالإنجليزي"
        case .fix: "زر التصليح"
        }
    }
}

/// Which rules are on. Mirrors the panel switches.
nonisolated struct Rules: Sendable, Equatable {
    var linkFields = true
    var textDecides = true
    var chatMemory = true
}

/// One place for the precedence: link field > per-chat memory > detected text > leave unchanged.
nonisolated enum Decider {
    static func decide(isLinkField: Bool, remembered: Lang?, detected: Lang?, rules: Rules) -> (Lang, Reason)? {
        if rules.linkFields, isLinkField { return (.en, .linkField) }
        if isLinkField { return nil }
        if rules.chatMemory, let remembered { return (remembered, .memory) }
        if rules.textDecides, let detected { return (detected, .text(detected)) }
        return nil
    }
}
