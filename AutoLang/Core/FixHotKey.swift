import AppKit
import Carbon

/// The fix button: ⌥⇧Space turns the last word (or the selected text) typed in the wrong layout into the right one.
final class FixHotKey {
    static var shared: FixHotKey?
    var onFix: (Lang) -> Void = { _ in }

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var converter: LayoutConverter?

    func register() {
        guard hotKeyRef == nil else { return }
        FixHotKey.shared = self
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, _, _ in
            MainActor.assumeIsolated { FixHotKey.shared?.fire() }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &type, nil, &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x414C_4E47), id: 1)   // "ALNG"
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey | shiftKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func fire() {
        guard AXIsProcessTrusted() else { return }
        if converter == nil { converter = LayoutConverter() }
        guard let converter else { return }
        let pasteboard = NSPasteboard.general
        let saved = Self.snapshot(pasteboard)

        let hasSelection = NSWorkspace.shared.frontmostApplication
            .flatMap { AX.focusedElement(pid: $0.processIdentifier) }
            .map { !AX.string($0, kAXSelectedTextAttribute).isEmpty } ?? false
        if !hasSelection { Self.press(UInt16(kVK_LeftArrow), flags: [.maskAlternate, .maskShift]) }   // select previous word
        pasteboard.clearContents()
        let before = pasteboard.changeCount
        Self.press(UInt16(kVK_ANSI_C), flags: .maskCommand)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard pasteboard.changeCount != before, let text = pasteboard.string(forType: .string), !text.isEmpty else {
                Self.restore(saved, to: pasteboard); return
            }
            let result = converter.fix(text)
            pasteboard.clearContents()
            pasteboard.setString(result.text, forType: .string)
            Self.press(UInt16(kVK_ANSI_V), flags: .maskCommand)
            self.onFix(result.lang)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { Self.restore(saved, to: pasteboard) }
        }
    }

    private static func press(_ key: UInt16, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
    }

    private static func restore(_ saved: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = saved.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}
