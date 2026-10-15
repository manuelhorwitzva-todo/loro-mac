import AppKit
import ApplicationServices
import Foundation

/// Mete el texto donde está el cursor. Prueba dos caminos, en orden:
/// 1. Accessibility: reemplaza la selección del campo enfocado (`kAXSelectedTextAttribute`).
///    No toca el portapapeles y no depende de que la app responda a ⌘V.
/// 2. Portapapeles + ⌘V sintético, y después devuelve lo que había copiado. Es el
///    fallback para apps que no exponen bien AX (Electron, algunos editores).
@MainActor
public enum Paster {
    public enum Outcome: Sendable { case accessibility, pasted, copiedOnly }

    /// Espera antes de mandar ⌘V, para que el portapapeles ya tenga el texto nuevo.
    private static let pasteDelay: Duration = .milliseconds(40)
    /// Espera antes de restaurar el portapapeles: la app receptora tiene que alcanzar a leerlo.
    private static let restoreDelay: Duration = .milliseconds(500)
    private static let keyV: CGKeyCode = 9

    @discardableResult
    public static func insert(_ text: String, allowPaste: Bool = true) -> Outcome {
        if text.isEmpty { return .copiedOnly }
        if writeIntoFocusedField(text) { return .accessibility }
        if !allowPaste {
            copyOnly(text)
            return .copiedOnly
        }
        pasteThroughClipboard(text)
        return .pasted
    }

    public static func copyOnly(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    // MARK: - Accessibility

    private static func writeIntoFocusedField(_ text: String) -> Bool {
        guard let field = focusedElement(), canSetSelectedText(field),
              let rangeBefore = selection(in: field) else { return false }
        let status = AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, text as CFString)
        guard status == .success, let rangeAfter = selection(in: field) else { return false }
        // Algunas apps responden "success" sin escribir nada. Si el cursor no se movió, no confiamos.
        let cursorMoved = rangeAfter.location != rangeBefore.location || rangeAfter.length != rangeBefore.length
        return cursorMoved
    }

    private static func focusedElement() -> AXUIElement? {
        var ref: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
                                                   kAXFocusedUIElementAttribute as CFString, &ref)
        guard status == .success, let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    private static func canSetSelectedText(_ field: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        let status = AXUIElementIsAttributeSettable(field, kAXSelectedTextAttribute as CFString, &settable)
        return status == .success && settable.boolValue
    }

    private static func selection(in field: AXUIElement) -> CFRange? {
        var ref: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &ref)
        guard status == .success, let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        let value = ref as! AXValue
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetType(value) == .cfRange, AXValueGetValue(value, .cfRange, &range) else { return nil }
        return range
    }

    // MARK: - Portapapeles + ⌘V

    /// Copia de todo lo que había en el portapapeles: cada ítem con todos sus tipos.
    private typealias ClipboardBackup = [[(NSPasteboard.PasteboardType, Data)]]

    private static func pasteThroughClipboard(_ text: String) {
        let board = NSPasteboard.general
        let backup = backUp(board)
        copyOnly(text)
        Task { @MainActor in
            try? await Task.sleep(for: pasteDelay)
            pressCommandV()
            try? await Task.sleep(for: restoreDelay)
            put(backup, into: board)
        }
    }

    private static func pressCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: isDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    private static func backUp(_ board: NSPasteboard) -> ClipboardBackup {
        guard let items = board.pasteboardItems else { return [] }
        return items.map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
    }

    private static func put(_ backup: ClipboardBackup, into board: NSPasteboard) {
        if backup.isEmpty { return }
        board.clearContents()
        let items: [NSPasteboardItem] = backup.map { pairs in
            let item = NSPasteboardItem()
            pairs.forEach { type, data in item.setData(data, forType: type) }
            return item
        }
        board.writeObjects(items)
    }
}
