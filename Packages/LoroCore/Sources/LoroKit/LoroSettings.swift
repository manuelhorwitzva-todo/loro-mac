import Foundation
import LoroCore

/// Preferencias de Loro. Se guardan en un archivo compartido
/// (~/Library/Application Support/Loro/settings.json) para que otras apps que embeben
/// LoroKit (ej. Nido) lean la MISMA configuración: motor, atajo, muletillas, etc.
public struct LoroSettings: Codable, Equatable, Sendable {
    public enum HotkeyMode: String, Codable, CaseIterable, Identifiable, Sendable {
        case pushToTalk, toggle, hybrid
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .pushToTalk: "Mantener presionado"
            case .toggle: "Presionar para empezar / parar"
            case .hybrid: "Ambos: mantener, o un toque para empezar y otro para parar"
            }
        }
        /// Un toque más corto que esto es "tap" en modo híbrido: la grabación sigue al soltar.
        public static let tapThreshold: TimeInterval = 0.4
    }

    /// Apple por default: en la auditoría del 10-sep (104 dictados reales) fue el más rápido
    /// (0,2 s) y el único junto a Whisper que no se desvía de idioma; Parakeet se desvió ~50%.
    public var engine: EngineKind = .apple
    public var whisperModel: String = WhisperEngine.defaultModel
    /// "es", "en" o "auto". Fijo por default: evita que Whisper traduzca al mezclar idiomas.
    public var whisperLanguage: String = "es"
    public var appleLocale: String = "es_CL"
    /// Filtro determinista de muletillas (sin modelo).
    public var fillerFilter: Bool = true
    public var hotkey: Hotkey = .rightOption
    public var hotkeyMode: HotkeyMode = .hybrid
    public var pasteAfterTranscribe: Bool = true
    /// Al terminar, el texto queda en el portapapeles y espera: Enter lo pega donde está el
    /// cursor, Esc lo deja solo en el portapapeles. Nada se escribe sin que el usuario lo pida.
    public var confirmWithEnter: Bool = true
    public var playSounds: Bool = true
    public var keepHistory: Bool = true
    /// Guarda el audio de cada dictado junto al historial (misma retención). Es lo único que
    /// permite distinguir un error del motor de una mala dicción y comparar motores con audio real.
    public var keepAudio: Bool = true
    /// Procesador de voz de Apple: filtra ruido de fondo y voces lejanas.
    public var voiceIsolation: Bool = false
    public var onboardingDone: Bool = false

    public init() {}

    public static let legacyDefaultsKey = "cl.manulit0.loro.settings"
    public static var fileURL: URL { ModelStore.root.appendingPathComponent("settings.json") }

    public static func load() -> LoroSettings {
        if let data = try? Data(contentsOf: fileURL), let s = try? JSONDecoder().decode(LoroSettings.self, from: data) {
            return s
        }
        // Migración desde UserDefaults (versiones anteriores de Loro).
        if let data = UserDefaults.standard.data(forKey: legacyDefaultsKey),
           let s = try? JSONDecoder().decode(LoroSettings.self, from: data) {
            s.save()
            return s
        }
        let fresh = LoroSettings()
        fresh.save()   // dejamos el archivo para que otras apps (Nido) lo encuentren
        return fresh
    }

    public func save() {
        try? FileManager.default.createDirectory(at: ModelStore.root, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: Self.fileURL, options: .atomic)
    }
}

/// Teclas que sirven de push-to-talk. Modificadores sueltos (Option derecho, etc.) son ideales
/// porque no escriben nada en la app activa mientras los mantienes.
public enum Hotkey: String, Codable, CaseIterable, Identifiable, Sendable {
    case rightOption, rightCommand, rightControl, fn, f13, f18, f19

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .rightOption: "⌥ Option derecho"
        case .rightCommand: "⌘ Command derecho"
        case .rightControl: "⌃ Control derecho"
        case .fn: "fn / 🌐"
        case .f13: "F13"
        case .f18: "F18"
        case .f19: "F19"
        }
    }

    /// Keycode de hardware (Carbon). Los modificadores llegan como flagsChanged, las F como keyDown/Up.
    public var keyCode: Int64 {
        switch self {
        case .rightOption: 61
        case .rightCommand: 54
        case .rightControl: 62
        case .fn: 63
        case .f13: 105
        case .f18: 79
        case .f19: 80
        }
    }

    public var isModifier: Bool {
        switch self {
        case .rightOption, .rightCommand, .rightControl, .fn: true
        default: false
        }
    }

    public var warning: String? {
        self == .fn ? "Revisa en Ajustes → Teclado que “Al presionar la tecla 🌐” esté en “No hacer nada”, o chocará con el dictado de macOS." : nil
    }
}
