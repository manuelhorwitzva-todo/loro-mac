import AppKit
import ApplicationServices
import Foundation

/// Escucha el teclado a nivel de sistema con un CGEventTap. Es la única forma de que el
/// push-to-talk funcione con cualquier app al frente, y por eso requiere el permiso de
/// Accesibilidad (y que la app NO esté en sandbox).
@MainActor
public final class HotkeyMonitor {
    public var onPress: (() -> Void)?
    public var onRelease: (() -> Void)?
    public var onEscape: (() -> Void)?
    /// Enter (teclado o numérico). Devuelve true para CONSUMIR la tecla: la app al frente no
    /// la ve. Es lo que permite "Enter pega el dictado" sin mandar un salto de línea de más.
    public var onReturn: (() -> Bool)?

    /// Bundle ids de apps que, estando al frente, hacen que ESTE monitor ignore el atajo.
    /// Loro pone aquí a Nido para no pegar dos veces cuando ambos escuchan la misma tecla.
    public var yieldWhenFrontmost: Set<String> = []
    /// Si no está vacío, este monitor solo reacciona cuando la app al frente es una de estas.
    /// Es el inverso: Nido pone su propio bundle id.
    public var captureOnlyWhenFrontmost: Set<String> = []

    public private(set) var hotkey: Hotkey = .rightOption
    private var eventTap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var isHeld = false

    private enum Key {
        static let escape: Int64 = 53
        static let returnKey: Int64 = 36
        static let keypadEnter: Int64 = 76
    }

    public init() {}

    public static var hasAccessibility: Bool { AXIsProcessTrusted() }

    public static func requestAccessibility() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    public static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Instala el tap para `hotkey`. Devuelve false si macOS no lo deja (falta Accesibilidad).
    public func start(hotkey: Hotkey) -> Bool {
        stop()
        self.hotkey = hotkey
        let events: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let mask = events.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        // defaultTap (no listenOnly) para poder consumir Enter cuando hay un dictado esperando.
        // Todo lo demás se devuelve intacto.
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: Self.tapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        eventTap = port
        tapSource = source
        return true
    }

    public func stop() {
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        eventTap = nil
        tapSource = nil
        isHeld = false
    }

    /// Callback C del tap. No puede capturar contexto: el monitor llega por `userInfo`.
    private static let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        let passThrough = Unmanaged.passUnretained(event)
        guard let userInfo else { return passThrough }
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        // CGEvent no es Sendable: sacamos los valores primitivos antes de cruzar al actor.
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let swallow = monitor.process(type: type, keyCode: keyCode, flags: event.flags)
        return swallow ? nil : passThrough
    }

    // El callback del tap llega en el run loop principal (lo agregamos ahí), así que es seguro
    // tocar estado @MainActor; `assumeIsolated` se lo dice al compilador.
    /// Devuelve true si la tecla se consume (solo Enter, cuando `onReturn` lo pide).
    nonisolated private func process(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> Bool {
        MainActor.assumeIsolated {
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                // macOS apaga el tap si tardamos mucho; lo re-encendemos.
                if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
                return false
            }
            if hotkey.isModifier {
                if type == .flagsChanged, keyCode == hotkey.keyCode {
                    setHeld(Self.isModifierDown(hotkey, in: flags))
                    return false
                }
            } else if keyCode == hotkey.keyCode, type == .keyDown || type == .keyUp {
                // Escape y Enter tienen prioridad sobre un atajo que no es modificador.
                if type == .keyUp { setHeld(false); return false }
                if keyCode != Key.escape, keyCode != Key.returnKey, keyCode != Key.keypadEnter {
                    setHeld(true)
                    return false
                }
            }
            guard type == .keyDown else { return false }
            switch keyCode {
            case Key.escape: onEscape?()
            case Key.returnKey, Key.keypadEnter: return onReturn?() ?? false
            default: break
            }
            return false
        }
    }

    /// ¿Le toca a este monitor reaccionar con la app que está al frente ahora?
    private var frontAppAllowsCapture: Bool {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if yieldWhenFrontmost.contains(front) { return false }
        return captureOnlyWhenFrontmost.isEmpty || captureOnlyWhenFrontmost.contains(front)
    }

    private func setHeld(_ held: Bool) {
        if held == isHeld { return }
        // Se decide al PRESIONAR; la soltada siempre cierra lo que se abrió, para no dejar
        // un micrófono grabando si el usuario cambia de app con la tecla apretada.
        if held && !frontAppAllowsCapture { return }
        isHeld = held
        if held { onPress?() } else { onRelease?() }
    }

    private static func isModifierDown(_ hotkey: Hotkey, in flags: CGEventFlags) -> Bool {
        switch hotkey {
        case .rightOption: flags.contains(.maskAlternate)
        case .rightCommand: flags.contains(.maskCommand)
        case .rightControl: flags.contains(.maskControl)
        case .fn: flags.contains(.maskSecondaryFn)
        default: false
        }
    }
}
