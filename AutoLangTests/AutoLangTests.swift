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
