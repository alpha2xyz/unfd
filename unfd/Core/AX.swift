import ApplicationServices
import Foundation

/// Small wrappers over the Accessibility API (reading other apps' fields and text).
nonisolated enum AX {
    static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var out: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success ? out : nil
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String {
        (value(element, attribute) as? String) ?? ""
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let raw = value(element, attribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func focusedElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        return element(app, kAXFocusedUIElementAttribute)
    }

    /// Chromium and Electron apps (Chrome, Claude, Slack) build their tree only when asked.
    static func enableManualAccessibility(pid: pid_t) {
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
}

/// The few facts about a focused field that the rules need. Pure data, so the rules can be tested.
nonisolated struct FieldInfo: Sendable, Equatable {
    var bundleID: String
    var role: String
    var subrole: String
    var identifier: String
    var labels: [String]      // title, description, placeholder, help
    var ownText: String

    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    var isTextEntry: Bool { Self.textRoles.contains(role) || subrole == "AXSearchField" || subrole == "AXSecureTextField" }

    /// Address bars, link, email and password fields: always English.
    var isLinkField: Bool {
        if subrole == "AXSecureTextField" { return true }
        if identifier == "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD" { return true }          // Safari
        let haystack = ([identifier] + labels).joined(separator: " ").lowercased()
        let keys = ["address and search bar", "search or enter address", "search or type url", "address bar",
                    "e-mail", "email", "url", "website", "web site", "البريد", "الإيميل", "الرابط", "عنوان الموقع"]
        return keys.contains { haystack.contains($0) }
    }

    /// Spotlight's search panel: on macOS 27 it belongs to the Siri process (`com.apple.campo`, probed live
    /// 2026-10-14); earlier macOS versions use `com.apple.Spotlight`.
    static let spotlightApps = ["com.apple.campo", "com.apple.Spotlight"]
    /// Spotlight and System Settings: what he types there (settings names, apps, files) follows the Mac's language.
    static let systemApps = Set(spotlightApps + ["com.apple.systempreferences"])
    var isSystemField: Bool { Self.systemApps.contains(bundleID) }
}

/// What the app read around the focused field.
nonisolated struct FieldContext: Sendable {
    var field: FieldInfo
    var chatKey: String
    var chatName: String
    var texts: [String]        // closest first
    var isChat = false         // true only when the WhatsApp reader returned a chat name
    var readsMessages = false  // texts are the chat's latest messages (WhatsApp chat or Claude), so they decide
}

/// Reads the focused field and the text near it. Runs off the main thread; every walk is capped.
nonisolated enum ContextReader {
    static let maxElements = 300
    static let maxSeconds = 0.1
    static let maxPieces = 6

    static func fieldInfo(_ element: AXUIElement, bundleID: String) -> FieldInfo {
        FieldInfo(
            bundleID: bundleID,
            role: AX.string(element, kAXRoleAttribute),
            subrole: AX.string(element, kAXSubroleAttribute),
            identifier: AX.string(element, kAXIdentifierAttribute),
            labels: [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute, kAXHelpAttribute]
                .map { AX.string(element, $0) }.filter { !$0.isEmpty },
            ownText: AX.string(element, kAXValueAttribute))
    }

    static func read(_ element: AXUIElement, bundleID: String) -> FieldContext {
        let field = fieldInfo(element, bundleID: bundleID)
        let window = AX.element(element, kAXWindowAttribute)
        let windowTitle = window.map { AX.string($0, kAXTitleAttribute) } ?? ""
        var chatName = ""
        var texts: [String] = []

        if !field.isLinkField && !field.isSystemField {
            if bundleID == "net.whatsapp.WhatsApp", let window {
                (chatName, texts) = readWhatsApp(window)
            }
            if bundleID == claudeApp { texts = readClaude(element) }
            let own = ScriptDetector.letterCounts(field.ownText)
            if own.arabic + own.latin >= 2 { texts.insert(field.ownText, at: 0) }
        }
        let name = chatName.isEmpty ? windowTitle : chatName
        return FieldContext(field: field, chatKey: "\(bundleID)|\(name)", chatName: name, texts: texts, isChat: !chatName.isEmpty,
                            readsMessages: !chatName.isEmpty || bundleID == claudeApp)
    }

    static let claudeApp = "com.anthropic.claudefordesktop"

    /// Claude desktop (probed 2026-10-28): his own messages are groups whose DOM class list holds a `…user-message…`
    /// class (`bg-[var(--cds-bg-user-message)]`); Claude's replies are left out, they are often English tool output.
    /// Walks back from the composer through what comes before it, newest first. No bubble found = today's fallback.
    static func readClaude(_ field: AXUIElement) -> [String] {
        var bubbles: [String] = [], seen = 0
        let start = Date()
        func isOver() -> Bool { bubbles.count >= maxPieces || seen >= maxElements || Date().timeIntervalSince(start) >= maxSeconds }
        func text(_ node: AXUIElement) -> String {
            if AX.string(node, kAXRoleAttribute) == "AXStaticText" { return AX.string(node, kAXValueAttribute) }
            return AX.children(node).map(text).joined(separator: " ")
        }
        func walk(_ node: AXUIElement) {
            guard !isOver() else { return }
            seen += 1
            let classes = (AX.value(node, "AXDOMClassList") as? [String]) ?? []
            if classes.contains(where: { $0.contains("user-message") }) {
                let message = text(node)
                if !message.isEmpty { bubbles.append(message) }
                return
            }
            for child in AX.children(node).reversed() { walk(child) }
        }
        var node = field
        while !isOver(), let parent = AX.element(node, kAXParentAttribute) {
            let siblings = AX.children(parent)
            if let index = siblings.firstIndex(where: { CFEqual($0, node) }) {
                for sibling in siblings[..<index].reversed() { walk(sibling) }
            }
            if AX.string(parent, kAXRoleAttribute) == "AXWindow" { break }
            node = parent
        }
        return bubbles
    }

    /// WhatsApp (probed 2026-10-11): messages are `WAMessageBubbleTableViewCell` items in `ChatMessagesTableView`;
    /// the chat name is the description of `NavigationBar_HeaderViewButton`.
    static func readWhatsApp(_ window: AXUIElement) -> (String, [String]) {
        var chatName = "", bubbles: [String] = []
        var queue = [window], seen = 0
        let start = Date()
        while !queue.isEmpty, seen < maxElements, Date().timeIntervalSince(start) < maxSeconds {
            let node = queue.removeFirst(); seen += 1
            let id = AX.string(node, kAXIdentifierAttribute)
            if id == "NavigationBar_HeaderViewButton" { chatName = AX.string(node, kAXDescriptionAttribute) }
            if id == "ChatMessagesTableView" {
                bubbles = AX.children(node)
                    .filter { AX.string($0, kAXIdentifierAttribute) == "WAMessageBubbleTableViewCell" }
                    .map { AX.string($0, kAXDescriptionAttribute) }
                    .filter { !$0.isEmpty }
                    .reversed()
                continue
            }
            queue += AX.children(node)
        }
        return (chatName, Array(bubbles.prefix(maxPieces)))
    }

    /// The chat-name button in WhatsApp's header, found once and then read cheaply on every check.
    static func findWhatsAppHeader(_ window: AXUIElement) -> AXUIElement? {
        var queue = [window], seen = 0
        while !queue.isEmpty, seen < 120 {
            let node = queue.removeFirst(); seen += 1
            if AX.string(node, kAXIdentifierAttribute) == "NavigationBar_HeaderViewButton" { return node }
            if AX.string(node, kAXIdentifierAttribute) == "ChatMessagesTableView" { continue }
            queue += AX.children(node)
        }
        return nil
    }
}
