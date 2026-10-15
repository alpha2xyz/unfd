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
        #expect(Decider.decide(isLinkField: false, remembered: nil, detected: .ar, rules: all)?.0 == .ar)
        #expect(Decider.decide(isLinkField: false, remembered: nil, detected: nil, rules: all) == nil)
        var noMemory = all; noMemory.chatMemory = false
        #expect(Decider.decide(isLinkField: false, remembered: .en, detected: .ar, rules: noMemory)?.0 == .ar)
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
        #expect(Decider.decide(isLinkField: false, isSystemField: true, systemLang: .en,
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
        #expect(Learner.key(for: field("com.google.Chrome"), isChat: false) == nil)                         // browser
        #expect(Learner.key(for: field("com.apple.Safari"), isChat: false) == nil)
    }
    @Test func precedenceWithLearning() {
        let all = Rules()
        #expect(Decider.decide(isLinkField: false, remembered: .en, learned: .ar, detected: .ar, rules: all)! == (.en, .memory))
        #expect(Decider.decide(isLinkField: false, remembered: nil, learned: .en, detected: .ar, rules: all)! == (.en, .learned))
        #expect(Decider.decide(isLinkField: true, remembered: nil, learned: .ar, detected: .ar, rules: all)?.0 == .en)
        #expect(Decider.decide(isLinkField: false, isSystemField: true, systemLang: .en,
                               remembered: nil, learned: .ar, detected: .ar, rules: all)! == (.en, .systemField))
        var off = all; off.learn = false
        #expect(Decider.decide(isLinkField: false, remembered: nil, learned: .en, detected: .ar, rules: off)! == (.ar, .text(.ar)))
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
