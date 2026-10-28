import Foundation

/// The two keyboard languages the app switches between.
nonisolated enum Lang: String, Codable, Sendable, CaseIterable {
    case ar, en

    var menuBarLabel: String { self == .ar ? "ع" : "EN" }
    var arabicName: String { self == .ar ? "عربي" : "إنجليزي" }

    /// The Mac's own language (first of System Settings → Language & Region), e.g. "en-SA" → English.
    static func system(preferred: String? = Locale.preferredLanguages.first) -> Lang {
        (preferred ?? "").lowercased().hasPrefix("ar") ? .ar : .en
    }
}

/// Why the app picked a language. Shown in the panel's "now" line.
nonisolated enum Reason: Sendable, Equatable {
    case linkField
    case systemField
    case memory
    case learned
    case text(Lang)
    case fix
    case slash
    case autoFix
    case undoFix
    case device

    var arabic: String {
        switch self {
        case .linkField: "خانة رابط أو عنوان"
        case .systemField: "خانة من النظام، تتبع لغة الجهاز"
        case .memory: "اخترتها بيدك لهذي المحادثة"
        case .learned: "تعلّمتها من تصحيحاتك في هذا البرنامج"
        case .text(.ar): "آخر الكلام بالعربي"
        case .text(.en): "آخر الكلام بالإنجليزي"
        case .fix: "زر التصليح"
        case .slash: "أمر يبدأ بـ /"
        case .autoFix: "صحّحت الكلمة تلقائيًا"
        case .undoFix: "تراجعت عن التصحيح التلقائي"
        case .device: "لغة الجهاز، الأساس لأي خانة"
        }
    }
}

/// Which rules are on. Mirrors the panel switches.
nonisolated struct Rules: Sendable, Equatable {
    var linkFields = true
    var systemFields = true
    var textDecides = true
    var chatMemory = true
    var slashCommands = true
    var learn = true
    var autoFix = false
}

/// One place for the precedence: link field > system field (Spotlight, System Settings) > the field's own text
/// (what he already wrote there) > per-chat memory > learned from his corrections > last chat messages (WhatsApp chat, his own messages in Claude)
/// > the Mac's language, the base for every other field.
nonisolated enum Decider {
    static func decide(isLinkField: Bool, isSystemField: Bool = false, isChat: Bool = false, systemLang: Lang = .en,
                       fieldText: Lang? = nil, remembered: Lang?, learned: Lang? = nil, detected: Lang?,
                       rules: Rules) -> (Lang, Reason)? {
        if rules.linkFields, isLinkField { return (.en, .linkField) }
        if isLinkField { return nil }
        if rules.systemFields, isSystemField { return (systemLang, .systemField) }
        if rules.textDecides, let fieldText { return (fieldText, .text(fieldText)) }
        if rules.chatMemory, let remembered { return (remembered, .memory) }
        if rules.learn, let learned { return (learned, .learned) }
        if isChat, rules.textDecides, let detected { return (detected, .text(detected)) }
        return (systemLang, .device)
    }
}
