import Foundation
import Testing
@testable import AutoLang

struct ScriptDetectorTests {
    @Test func arabicMessages() { #expect(ScriptDetector.detect(["السلام عليكم، كيف الحال؟"]) == .ar) }
    @Test func englishMessages() { #expect(ScriptDetector.detect(["See you at 5 tomorrow"]) == .en) }
    @Test func latestMessageLeads() {
        #expect(ScriptDetector.detect(["ok thanks", "تمام، أرسلت لك الملف قبل شوي وراجعه لو سمحت"]) == .en)
    }
    @Test func arabicWithTimeStamp() { #expect(ScriptDetector.detect(["أبو فهد: وصلت الرياض، 10:42 PM Read"]) == .ar) }
    @Test func emptyAndDigitsGiveNothing() {
        #expect(ScriptDetector.detect([]) == nil)
        #expect(ScriptDetector.detect(["12:30", "  "]) == nil)
    }
}

struct LayoutConverterTests {
    let converter = LayoutConverter()!

    @Test func englishKeysToArabic() { #expect(converter.fix("hgsghl").text == "السلام") }
    @Test func arabicKeysToEnglish() {
        let result = converter.fix("اثممخ")
        #expect(result.text == "hello")
        #expect(result.lang == .en)
    }
    @Test func indicDigitsToWestern() { #expect(converter.fix("١٢٣").text == "123") }
    @Test func spacesStay() { #expect(converter.fix("hgsghl ugd;l").text == "السلام عليكم") }
}

struct RulesTests {
    func field(_ id: String = "", role: String = "AXTextField", subrole: String = "", labels: [String] = []) -> FieldInfo {
        FieldInfo(bundleID: "x", role: role, subrole: subrole, identifier: id, labels: labels, ownText: "")
    }

    @Test func safariAddressBarIsLink() { #expect(field("WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD").isLinkField) }
    @Test func chromeOmniboxIsLink() { #expect(field(labels: ["Address and search bar"]).isLinkField) }
    @Test func emailAndPasswordAreLink() {
        #expect(field(labels: ["Email address"]).isLinkField)
        #expect(field(subrole: "AXSecureTextField").isLinkField)
    }
    @Test func whatsAppComposerIsNotLink() {
        #expect(!field("ChatBar_ComposerTextView", role: "AXTextArea", labels: ["Type a message"]).isLinkField)
    }
    @Test func precedence() {
        let all = Rules()
        #expect(Decider.decide(isLinkField: true, remembered: .ar, detected: .ar, rules: all)?.0 == .en)
        #expect(Decider.decide(isLinkField: false, remembered: .en, detected: .ar, rules: all)?.0 == .en)
        #expect(Decider.decide(isLinkField: false, isChat: true, remembered: nil, detected: .ar, rules: all)?.0 == .ar)
        #expect(Decider.decide(isLinkField: false, remembered: nil, detected: nil, rules: all)! == (.en, .device))
        var noMemory = all; noMemory.chatMemory = false
        #expect(Decider.decide(isLinkField: false, isChat: true, remembered: .en, detected: .ar, rules: noMemory)?.0 == .ar)
    }
}

struct SystemFieldTests {
    func field(_ bundleID: String, role: String = "AXTextField", subrole: String = "") -> FieldInfo {
        FieldInfo(bundleID: bundleID, role: role, subrole: subrole, identifier: "", labels: [], ownText: "")
    }

    @Test func spotlightAndSettingsAreSystemFields() {
        #expect(field("com.apple.Spotlight").isSystemField)
        #expect(field("com.apple.campo").isSystemField)   // macOS 27: Spotlight's panel lives in the Siri process
        #expect(field("com.apple.systempreferences", subrole: "AXSearchField").isSystemField)
        #expect(!field("net.whatsapp.WhatsApp").isSystemField)
    }
    @Test func systemLanguageFromPreferred() {
        #expect(Lang.system(preferred: "en-SA") == .en)
        #expect(Lang.system(preferred: "ar-SA") == .ar)
        #expect(Lang.system(preferred: "ar") == .ar)
        #expect(Lang.system(preferred: nil) == .en)
    }
    @Test func systemFieldPrecedence() {
        let all = Rules()
        // Arabic chat memory and Arabic text do not beat the Mac's language in a system field.
        #expect(Decider.decide(isLinkField: false, isSystemField: true, systemLang: .en,
                               remembered: .ar, detected: .ar, rules: all)! == (.en, .systemField))
        #expect(Decider.decide(isLinkField: false, isSystemField: true, systemLang: .ar,
                               remembered: nil, detected: .en, rules: all)?.0 == .ar)
        // A password field inside System Settings stays English.
        #expect(Decider.decide(isLinkField: true, isSystemField: true, systemLang: .ar,
                               remembered: nil, detected: nil, rules: all)?.0 == .en)
        var off = all; off.systemFields = false
        #expect(Decider.decide(isLinkField: false, isSystemField: true, isChat: true, systemLang: .en,
                               remembered: nil, detected: .ar, rules: off)?.0 == .ar)
    }
}

struct SlashModeTests {
    /// Types `text` key by key and returns every action, in order.
    func type(_ text: String, from lang: Lang, mode: inout SlashMode) -> [SlashMode.Action] {
        var current: Lang = lang, actions: [SlashMode.Action] = []
        for ch in text {
            let key: SlashMode.Key = ch == " " ? .space : ch == "\n" ? .enter : .text(String(ch))
            if let action = mode.press(key, current: current) {
                actions.append(action)
                if case .toEnglish = action { current = .en }
                if case .restore(let l) = action { current = l }
            }
        }
        return actions
    }

    @Test func arabicSentenceWithCommand() {   // his note: «انا /advisor عشان»
        var mode = SlashMode()
        #expect(type("انا /advisor عشان", from: .ar, mode: &mode) == [.toEnglish, .restore(.ar)])
        #expect(!mode.isActive)
    }
    @Test func englishSentenceWithCommand() {  // his note: «i like /ads today report»
        var mode = SlashMode()
        #expect(type("i like /ads today report", from: .en, mode: &mode) == [.toEnglish, .restore(.en)])
    }
    @Test func commandAtFieldStart() {
        var mode = SlashMode()
        #expect(type("/model", from: .ar, mode: &mode) == [.toEnglish])
        #expect(mode.isActive)
        #expect(mode.press(.enter, current: .en) == .restore(.ar))
    }
    @Test func dateDoesNotStartIt() {
        var mode = SlashMode()
        #expect(type("موعدنا 10/2026 ", from: .ar, mode: &mode).isEmpty)
        #expect(type("a/b", from: .en, mode: &mode).isEmpty)
    }
    @Test func deletingTheSlashCancels() {
        var mode = SlashMode()
        _ = type(" /", from: .ar, mode: &mode)
        #expect(mode.press(.delete, current: .en) == .restore(.ar))
        _ = type(" /ad", from: .ar, mode: &mode)
        #expect(mode.press(.delete, current: .en) == nil)
        #expect(mode.isActive)
    }
    @Test func arrowsKeepTheCommand() {
        var mode = SlashMode()
        _ = type("/ad", from: .ar, mode: &mode)
        #expect(mode.press(.other, current: .en) == nil)
        #expect(mode.isActive)
        #expect(mode.press(.tab, current: .en) == .restore(.ar))
    }
    @Test func resetDropsWithoutSwitching() {
        var mode = SlashMode()
        _ = type("/ad", from: .ar, mode: &mode)
        mode.reset()
        #expect(!mode.isActive)
        #expect(mode.press(.space, current: .en) == nil)
    }
}

struct LearnerTests {
    func learner(_ langs: [Lang], key: String = "k") -> Learner {
        var l = Learner()
        for lang in langs { l.record(lang, for: key) }
        return l
    }

    @Test func threeInARowLearns() { #expect(learner([.ar, .ar, .ar]).learned(for: "k") == .ar) }
    @Test func twoIsNotEnough() { #expect(learner([.ar, .ar]).learned(for: "k") == nil) }
    @Test func mixedIsNil() { #expect(learner([.ar, .en, .ar]).learned(for: "k") == nil) }
    @Test func lastThreeDecide() {
        let l = learner([.en, .en, .en, .ar, .ar, .ar])
        #expect(l.learned(for: "k") == .ar)
        #expect(l.corrections["k"]?.count == 5)   // only the last 5 are kept
    }
    @Test func clearForgets() {
        var l = learner([.ar, .ar, .ar])
        #expect(l.count == 1)
        l.clear()
        #expect(l.learned(for: "k") == nil)
        #expect(l.count == 0)
    }
    @Test func keysAreSeparate() {
        var l = learner([.ar, .ar, .ar])
        l.record(.en, for: "other")
        #expect(l.learned(for: "other") == nil)
        #expect(l.count == 1)
    }
    @Test func codableRoundTrip() throws {
        let l = learner([.en, .ar, .ar, .ar])
        let back = try JSONDecoder().decode(Learner.self, from: JSONEncoder().encode(l))
        #expect(back == l)
        #expect(back.learned(for: "k") == .ar)
    }
}

struct PressClassifierTests {
    @Test func emptyFieldIsCorrection() { #expect(Learner.classify(typedSinceFocus: 0, fieldValue: "") == .correction) }
    @Test func whitespaceOnlyIsCorrection() { #expect(Learner.classify(typedSinceFocus: 0, fieldValue: " \n ") == .correction) }
    @Test func unreadableIsCorrection() { #expect(Learner.classify(typedSinceFocus: 0, fieldValue: nil) == .correction) }
    @Test func textInFieldIsMidText() { #expect(Learner.classify(typedSinceFocus: 0, fieldValue: "ابحث عن رمز") == .midText) }
    @Test func typedThenEmptiedIsMidText() { #expect(Learner.classify(typedSinceFocus: 5, fieldValue: "") == .midText) }
}

struct LearningRulesTests {
    func field(_ bundleID: String, role: String = "AXTextArea", subrole: String = "", labels: [String] = []) -> FieldInfo {
        FieldInfo(bundleID: bundleID, role: role, subrole: subrole, identifier: "", labels: labels, ownText: "")
    }

    @Test func plainFieldGetsAKey() {
        #expect(Learner.key(for: field("com.apple.Notes"), isChat: false) == "com.apple.Notes|AXTextArea|")
    }
    @Test func excludedPlacesGetNoKey() {
        #expect(Learner.key(for: field("com.apple.Notes", labels: ["Email"]), isChat: false) == nil)       // link field
        #expect(Learner.key(for: field("com.apple.Spotlight"), isChat: false) == nil)                       // system field
        #expect(Learner.key(for: field("net.whatsapp.WhatsApp"), isChat: true) == nil)                      // recognised chat
        #expect(Learner.key(for: field("com.anthropic.claudefordesktop"), isChat: true) == nil)             // Claude reads messages
        #expect(Learner.key(for: field("com.google.Chrome"), isChat: false) == nil)                         // browser
        #expect(Learner.key(for: field("com.apple.Safari"), isChat: false) == nil)
    }
    /// Claude on an English Mac: his Arabic messages decide; an empty chat falls back to the Mac's language.
    @Test func claudeFollowsHisMessages() {
        let all = Rules()
        #expect(Decider.decide(isLinkField: false, isChat: true, systemLang: .en, remembered: nil, learned: nil,
                               detected: .ar, rules: all)! == (.ar, .text(.ar)))
        #expect(Decider.decide(isLinkField: false, isChat: true, systemLang: .en, remembered: nil, learned: nil,
                               detected: nil, rules: all)! == (.en, .device))
    }
    @Test func precedenceWithLearning() {
        let all = Rules()
        #expect(Decider.decide(isLinkField: false, remembered: .en, learned: .ar, detected: .ar, rules: all)! == (.en, .memory))
        #expect(Decider.decide(isLinkField: false, remembered: nil, learned: .en, detected: .ar, rules: all)! == (.en, .learned))
        #expect(Decider.decide(isLinkField: true, remembered: nil, learned: .ar, detected: .ar, rules: all)?.0 == .en)
        #expect(Decider.decide(isLinkField: false, isSystemField: true, systemLang: .en,
                               remembered: nil, learned: .ar, detected: .ar, rules: all)! == (.en, .systemField))
        var off = all; off.learn = false
        #expect(Decider.decide(isLinkField: false, isChat: true, remembered: nil, learned: .en, detected: .ar, rules: off)! == (.ar, .text(.ar)))
    }
    @Test func fieldOwnTextWinsOverMemoryAndLearned() {
        let all = Rules()
        #expect(Decider.decide(isLinkField: false, fieldText: .ar, remembered: nil, learned: .en, detected: .en, rules: all)! == (.ar, .text(.ar)))
        #expect(Decider.decide(isLinkField: false, fieldText: .en, remembered: .ar, learned: nil, detected: .ar, rules: all)! == (.en, .text(.en)))
        #expect(Decider.decide(isLinkField: true, fieldText: .ar, remembered: nil, detected: .ar, rules: all)?.0 == .en)
        var off = all; off.textDecides = false
        #expect(Decider.decide(isLinkField: false, fieldText: .ar, remembered: nil, learned: .en, detected: .ar, rules: off)! == (.en, .learned))
        #expect(Decider.decide(isLinkField: false, fieldText: nil, remembered: nil, learned: .en, detected: .ar, rules: all)! == (.en, .learned))
    }
    @Test func deviceLanguageIsTheBase() {
        let all = Rules()
        #expect(Decider.decide(isLinkField: false, isChat: false, systemLang: .en, remembered: nil, detected: .ar, rules: all)! == (.en, .device))
        #expect(Decider.decide(isLinkField: false, isChat: true, remembered: nil, detected: .ar, rules: all)! == (.ar, .text(.ar)))
        #expect(Decider.decide(isLinkField: false, systemLang: .ar, remembered: nil, detected: nil, rules: all)! == (.ar, .device))
        #expect(Decider.decide(isLinkField: false, systemLang: .en, remembered: nil, learned: .ar, detected: nil, rules: all)! == (.ar, .learned))
        #expect(Decider.decide(isLinkField: false, systemLang: .en, fieldText: .ar, remembered: nil, detected: nil, rules: all)! == (.ar, .text(.ar)))
        var noLink = all; noLink.linkFields = false
        #expect(Decider.decide(isLinkField: true, remembered: nil, detected: nil, rules: noLink) == nil)
    }
    @Test func ownTextNeedsTwoLetters() {
        #expect(ScriptDetector.detectOwn("") == nil)
        #expect(ScriptDetector.detectOwn("م 1") == nil)
        #expect(ScriptDetector.detectOwn("مرحبا") == .ar)
        #expect(ScriptDetector.detectOwn("hello") == .en)
    }
    @Test func mixedSentenceStaysArabic() {
        #expect(ScriptDetector.detect(["ابحث عن رمز otp في الايميل"]) == .ar)
    }
}

struct ChatMemoryTests {
    @Test func keepsOnlyWhatsAppChats() {
        let saved: [String: Lang] = [
            "net.whatsapp.WhatsApp|Ahmed": .ar,
            "net.whatsapp.WhatsApp|\u{202A}+966 50 000 0000\u{202C}": .en,
            "net.whatsapp.WhatsApp|\u{200E}WhatsApp": .ar,
            "com.anthropic.claudefordesktop|Claude": .ar,
            "com.apple.TextEdit|Untitled": .en,
        ]
        let kept = AppModel.chatOnly(saved)
        #expect(Set(kept.keys) == ["net.whatsapp.WhatsApp|Ahmed", "net.whatsapp.WhatsApp|\u{202A}+966 50 000 0000\u{202C}"])
        #expect(kept["net.whatsapp.WhatsApp|Ahmed"] == .ar)
    }
    @Test func windowTitleOfWhatsAppIsNotAChat() {
        #expect(AppModel.chatOnly(["net.whatsapp.WhatsApp|WhatsApp": .ar, "net.whatsapp.WhatsApp|\u{200F} WhatsApp\u{200E}": .en]).isEmpty)
    }
    @Test func otherAppsAreDropped() {
        #expect(AppModel.chatOnly(["com.anthropic.claudefordesktop|Claude": .ar, "com.apple.TextEdit|Untitled": .en]).isEmpty)
    }
}

struct AutoFixTests {
    static let converter = LayoutConverter()!
    static let arabicList = ["لا", "من", "في", "هو", "هذا", "كيف", "وين", "وش", "السلام", "عليكم", "سقف", "ثوب", "فخ", "شكرا"]
    static let englishList = ["you", "i", "the", "to", "is", "hello", "ma", "im", "thanks", "world", "srt", "emf"]

    var lists: WordLists {
        WordLists(arabic: WordLists.parse(Self.arabicList.joined(separator: "\n")),
                  english: WordLists.parse(Self.englishList.joined(separator: "\n")))
    }

    /// Only what the lists hold is a word; the spell checkers accept what the test names.
    func detector(arabicSpelled: Set<String> = [], englishSpelled: Set<String> = []) -> AutoFixDetector {
        AutoFixDetector(words: lists, spelledArabic: { arabicSpelled.contains($0) }, spelledEnglish: { englishSpelled.contains($0) })
    }

    /// An Arabic word as the English layout shows it, and back.
    func typedEnglish(for arabic: String) -> (typed: String, converted: String) {
        let typed = Self.converter.convert(arabic, to: .en)
        return (typed, Self.converter.convert(typed, to: .ar))
    }

    func typedArabic(for english: String) -> (typed: String, converted: String) {
        let typed = Self.converter.convert(english, to: .ar)
        return (typed, Self.converter.convert(typed, to: .en))
    }

    @Test func arabicTypedOnEnglishLayoutIsFixed() {
        let w = typedEnglish(for: "السلام")
        #expect(w.typed == "hgsghl")
        #expect(detector().check(typed: w.typed, converted: w.converted, context: .init()) == .init(text: "السلام", lang: .ar))
    }

    @Test func englishTypedOnArabicLayoutIsFixed() {
        let w = typedArabic(for: "hello")
        #expect(detector().check(typed: w.typed, converted: w.converted, context: .init()) == .init(text: "hello", lang: .en))
    }

    @Test func realEnglishWordStays() {
        // "ma" (rank 571) and "srt" are in the English list: typed on purpose, unless the context says Arabic.
        let ma = typedEnglish(for: "وش"), srt = typedEnglish(for: "سقف")
        #expect(srt.typed == "srt")
        #expect(detector().check(typed: ma.typed, converted: ma.converted, context: .init()) == nil)
        #expect(detector().check(typed: srt.typed, converted: srt.converted, context: .init()) == nil)
        #expect(detector().check(typed: srt.typed, converted: srt.converted, context: .init(previousFixed: .ar))?.text == "سقف")
    }

    @Test func twoLetterWordsNeedContext() {
        let im = typedEnglish(for: "هو")
        #expect(detector().check(typed: im.typed, converted: im.converted, context: .init()) == nil)
        #expect(detector().check(typed: im.typed, converted: im.converted, context: .init(previousFixed: .ar))?.text == "هو")
        #expect(detector().check(typed: im.typed, converted: im.converted, context: .init(fieldLang: .ar))?.text == "هو")
        #expect(detector().check(typed: im.typed, converted: im.converted, context: .init(previousFixed: .en, fieldLang: .en)) == nil)
    }

    @Test func oneLetterNever() {
        let w = typedEnglish(for: "و")
        #expect(detector().check(typed: w.typed, converted: w.converted, context: .init(previousFixed: .ar, fieldLang: .ar)) == nil)
    }

    @Test func spellCheckerGuardsEnglish() {
        // "wrld" is not in the list, but the English checker knows it: it stays.
        let w = typedEnglish(for: Self.converter.convert("wrld", to: .ar))
        let fake = lists
        var listsWithWord = fake; listsWithWord.arabic[w.converted] = 999
        let d = AutoFixDetector(words: listsWithWord, spelledArabic: { _ in false }, spelledEnglish: { $0 == "wrld" })
        #expect(d.check(typed: w.typed, converted: w.converted, context: .init()) == nil)
    }

    @Test func rareArabicWordIsNotTurnedEnglish() {
        // لهب is outside the list but a real word (the Arabic checker accepts it): never "gif" or anything else.
        let w = typedArabic(for: "gif")
        var withGif = lists; withGif.english["gif"] = 500
        let d = AutoFixDetector(words: withGif, spelledArabic: { $0 == "لهب" }, spelledEnglish: { _ in false })
        #expect(w.typed == "لهب")
        #expect(d.check(typed: w.typed, converted: w.converted, context: .init()) == nil)
        // The same keys with a checker that rejects the Arabic form: fixed.
        let loose = AutoFixDetector(words: withGif, spelledArabic: { _ in false }, spelledEnglish: { _ in false })
        #expect(loose.check(typed: w.typed, converted: w.converted, context: .init())?.text == "gif")
    }

    @Test func rareEnglishTargetIsNotUsed() {
        var lists = lists; lists.english["zzzq"] = 40_000
        let w = typedArabic(for: "zzzq")
        let d = AutoFixDetector(words: lists, spelledArabic: { _ in false }, spelledEnglish: { _ in false })
        #expect(d.check(typed: w.typed, converted: w.converted, context: .init()) == nil)
    }

    @Test func trailingPunctuationIsKept() {
        let w = typedEnglish(for: "شكرا،")
        #expect(detector().check(typed: w.typed, converted: w.converted, context: .init())?.text == "شكرا،")
        let e = typedArabic(for: "thanks,")
        #expect(detector().check(typed: e.typed, converted: e.converted, context: .init())?.text == "thanks,")
        #expect(AutoFixDetector.stem("hello!?") == "hello")
        #expect(AutoFixDetector.trimmed("a;vh,") == "a;vh")
        let lak = typedEnglish(for: "لاك")   // ك sits on the ";" key: the typed word ends in punctuation that is a letter
        var withLak = lists; withLak.arabic["لاك"] = 100
        let d = AutoFixDetector(words: withLak, spelledArabic: { _ in false }, spelledEnglish: { _ in false })
        #expect(d.check(typed: lak.typed, converted: lak.converted, context: .init())?.text == "لاك")
        #expect(AutoFixDetector.stem("a1b") == nil)
        #expect(AutoFixDetector.stem("...") == nil)
    }

    @Test func undoneWordIsSkipped() {
        let w = typedEnglish(for: "السلام")
        #expect(detector().check(typed: w.typed, converted: w.converted, context: .init(), skip: [w.typed]) == nil)
    }

    @Test func mixedAndDigitsStay() {
        #expect(detector().check(typed: "hg1", converted: "ال1", context: .init()) == nil)
        #expect(detector().check(typed: "12", converted: "12", context: .init(previousFixed: .ar)) == nil)
    }

    @Test func bufferReadsKeysInBothLayouts() {
        let english = LayoutConverter.keyMap(layoutID: InputSourceIDs.abc)!
        let arabic = LayoutConverter.keyMap(layoutID: InputSourceIDs.arabic123)!
        var buffer = WordBuffer()
        for code in [4, 5, 1, 5, 4, 37] { buffer.append(.init(code: code, shift: false), layoutID: "abc") }   // h g s g h l
        #expect(buffer.layoutID == "abc")
        #expect(buffer.text(in: english) == "hgsghl")
        #expect(buffer.text(in: arabic) == "السلام")
        buffer.backspace()
        #expect(buffer.text(in: english) == "hgsgh")
        buffer.append(.init(code: 49, shift: false), layoutID: "abc")   // Space is not a letter key
        #expect(buffer.text(in: english) == nil)
        buffer.append(.init(code: 4, shift: false), layoutID: "arabic")   // another layout starts a new word
        #expect(buffer.keys.count == 1 && buffer.layoutID == "arabic")
        buffer.clear()
        #expect(buffer.layoutID == nil)
        #expect(buffer.isEmpty)
        buffer.backspace()
        #expect(buffer.isEmpty)
    }

    @Test func undoWindow() {
        var undo = AutoFixUndo()
        let start = Date()
        let fix = AutoFixUndo.Pending(original: "hgsghl", fixed: "السلام", originalLang: .en, fixedLang: .ar, at: start)
        undo.fixed(fix)
        #expect(undo.keyPressed(isUndo: true, now: start.addingTimeInterval(2)) == fix)
        #expect(undo.pending == nil)
        #expect(undo.keyPressed(isUndo: true, now: start.addingTimeInterval(3)) == nil)   // used once
        undo.fixed(fix)
        #expect(undo.keyPressed(isUndo: true, now: start.addingTimeInterval(6)) == nil)   // too late
        undo.fixed(fix)
        #expect(undo.keyPressed(isUndo: false, now: start.addingTimeInterval(1)) == nil)   // another key closes it
        #expect(undo.keyPressed(isUndo: true, now: start.addingTimeInterval(1)) == nil)
    }

    @Test func listsParseInOrder() {
        let ranks = WordLists.parse("you\ni\n\nthe\nyou\n")
        #expect(ranks == ["you": 0, "i": 1, "the": 2])
        for name in ["ar", "en"] {
            let url = Bundle(for: BundleToken.self).url(forResource: name, withExtension: "txt")
                ?? Bundle.main.url(forResource: name, withExtension: "txt")
            #expect(url != nil, "\(name).txt is bundled")
        }
    }
}

private final class BundleToken {}
