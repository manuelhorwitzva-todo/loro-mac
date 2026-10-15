import Foundation

/// Una entrada del diccionario personal.
/// - `.term`: una palabra o nombre que debe escribirse con esta forma exacta ("GitHub").
///   Se busca sin distinguir mayúsculas ni tildes y se reescribe con la forma canónica.
/// - `.correction`: "cuando escuches X, escribe Y" ("cloud code" → "Claude Code").
public struct DictionaryEntry: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case term, correction
    }
    public var id: UUID
    public var kind: Kind
    /// Lo que se escribe (forma correcta).
    public var write: String
    /// Solo para `.correction`: lo que suele salir mal.
    public var hear: String
    public var isEnabled: Bool

    public init(id: UUID = UUID(), kind: Kind, write: String, hear: String = "", isEnabled: Bool = true) {
        self.id = id; self.kind = kind; self.write = write; self.hear = hear; self.isEnabled = isEnabled
    }
    public static func term(_ w: String) -> DictionaryEntry { DictionaryEntry(kind: .term, write: w) }
    public static func correction(_ hear: String, _ write: String) -> DictionaryEntry { DictionaryEntry(kind: .correction, write: write, hear: hear) }
}

/// Aplica el diccionario sobre un texto ya transcrito. Es post-corrección: Parakeet no
/// acepta vocabulario para sesgar el modelo, así que arreglamos la salida.
public struct DictionaryCorrector: Sendable {
    private struct Rule: Sendable {
        let regex: NSRegularExpression
        let replacement: String
    }
    private let rules: [Rule]
    public let enabledTerms: [String]

    public init(entries: [DictionaryEntry]) {
        let active = entries.filter { $0.isEnabled && !$0.write.trimmingCharacters(in: .whitespaces).isEmpty }
        enabledTerms = active.map(\.write)
        // Las coincidencias más largas primero, para que "Claude Code" gane a "Claude".
        var patterns: [(String, String)] = []
        for e in active {
            switch e.kind {
            case .term: patterns.append((e.write, e.write))
            case .correction where !e.hear.trimmingCharacters(in: .whitespaces).isEmpty: patterns.append((e.hear, e.write))
            default: break
            }
        }
        patterns.sort { $0.0.count > $1.0.count }
        rules = patterns.compactMap { hear, write in
            // Palabra completa: los límites son "no letra ni número" (\\b no entiende ñ/tildes).
            // Insensible a mayúsculas y a tildes gracias a Self.fold.
            let escaped = NSRegularExpression.escapedPattern(for: Self.fold(hear))
                .replacingOccurrences(of: " ", with: "\\s+")
            guard let re = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])", options: [.caseInsensitive]) else { return nil }
            return Rule(regex: re, replacement: write)
        }
    }

    /// Quita tildes para comparar ("Notion" == "nótion"), pero conserva la ñ como letra.
    static func fold(_ s: String) -> String {
        s.replacingOccurrences(of: "ñ", with: "\u{F8FF}").replacingOccurrences(of: "Ñ", with: "\u{F8FF}")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "\u{F8FF}", with: "ñ")
    }

    public func apply(_ text: String) -> String {
        guard !rules.isEmpty, !text.isEmpty else { return text }
        // Trabajamos sobre la versión sin tildes para encontrar, pero reemplazamos en el original.
        // Como fold() conserva la cantidad de caracteres (1 a 1), los rangos coinciden.
        var result = text
        for rule in rules {
            let folded = Self.fold(result)
            guard folded.count == result.count else { continue }
            let matches = rule.regex.matches(in: folded, range: NSRange(folded.startIndex..., in: folded))
            for m in matches.reversed() {
                guard let r = Range(m.range, in: folded) else { continue }
                let lo = result.index(result.startIndex, offsetBy: folded.distance(from: folded.startIndex, to: r.lowerBound))
                let hi = result.index(lo, offsetBy: folded.distance(from: r.lowerBound, to: r.upperBound))
                if String(result[lo..<hi]) != rule.replacement { result.replaceSubrange(lo..<hi, with: rule.replacement) }
            }
        }
        return result
    }
}

/// Persistencia del diccionario en Application Support/Loro/dictionary.json.
public enum DictionaryStore {
    public static var url: URL { ModelStore.root.appendingPathComponent("dictionary.json") }

    public static func load() -> [DictionaryEntry] {
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([DictionaryEntry].self, from: data) else {
            try? save(seed)   // primera vez: dejamos el archivo para que se pueda editar a mano
            return seed
        }
        return entries
    }

    public static func save(_ entries: [DictionaryEntry]) throws {
        try FileManager.default.createDirectory(at: ModelStore.root, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(entries).write(to: url, options: .atomic)
    }

    /// Vocabulario inicial: nombres y jerga de tecnología que los motores suelen escribir mal.
    public static let seed: [DictionaryEntry] = [
        .term("Loro"), .term("Wispr Flow"),
        .term("Claude"), .term("Claude Code"), .term("Anthropic"), .term("Cloud Run"),
        .term("Rails"), .term("Flutter"), .term("Kanban"), .term("TestFlight"),
        .term("Antigravity"), .term("Cursor"), .term("Xcode"), .term("SwiftUI"), .term("Notion"),
        .term("Parakeet"), .term("Whisper"), .term("GitHub"), .term("Telegram"), .term("WhatsApp"),
        .term("Analytics"), .term("onboarding"), .term("dashboard"), .term("churn rate"),
        .correction("cloud code", "Claude Code"), .correction("clau code", "Claude Code"),
        .correction("guisper", "Whisper"), .correction("güisper", "Whisper"),
        .correction("test flight", "TestFlight"), .correction("git hub", "GitHub"),
    ]
}
