import Foundation

/// Quita muletillas con reglas fijas, sin modelo: instantáneo y sin riesgo de borrar contenido.
/// Solo borra sonidos de duda ("eh", "um"). Las listas de frases ("como que", "o sea", "ya")
/// quedan vacías por default: en la auditoría del 7-sep borraban contenido ("me sale como que
/// tenéis" → "me sale tenéis") y cambiaban el tono. Se pueden rellenar por instancia.
public struct FillerFilter: Sendable {
    /// Palabras que se borran donde aparezcan (como palabra completa).
    public var standalone: [String] = ["eh", "ehh", "em", "emm", "ehm", "mmm", "um", "umm", "uh", "uhh", "hmm"]
    /// Frases que se borran solo al inicio de una oración (después de . ? ! o al comienzo),
    /// donde funcionan de arranque y no de contenido. "O sea" a mitad de frase puede ser contenido.
    public var sentenceStarters: [String] = []
    /// Frases que se borran en cualquier posición porque casi nunca aportan.
    public var anywhere: [String] = []

    public init() {}

    public func apply(_ text: String) -> String {
        var t = text
        for w in standalone {
            t = Self.remove("(?i)(?<![\\p{L}\\p{N}])\(NSRegularExpression.escapedPattern(for: w))(?![\\p{L}\\p{N}])[,.]?\\s*", in: t)
        }
        for w in anywhere {
            let p = NSRegularExpression.escapedPattern(for: w).replacingOccurrences(of: " ", with: "\\s+")
            t = Self.remove("(?i)(?<![\\p{L}\\p{N}])\(p)(?![\\p{L}\\p{N}])[,]?\\s*", in: t)
        }
        for w in sentenceStarters {
            let p = NSRegularExpression.escapedPattern(for: w).replacingOccurrences(of: " ", with: "\\s+")
            // Inicio absoluto o tras puntuación de cierre; la coma opcional que suele seguir.
            t = Self.remove("(?i)(?:^|(?<=[.!?¿¡]\\s{0,2}))\(p)(?![\\p{L}\\p{N}])[,]?\\s*", in: t)
        }
        // Limpieza: espacios dobles, espacio antes de puntuación.
        t = t.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\s+([,.;:!?])", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: ",\\s*,", with: ",", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ","))
            .trimmingCharacters(in: .whitespaces)
        guard let first = t.first else { return t }
        return String(first).uppercased() + t.dropFirst()
    }

    /// Borra cada match. Si lo borrado venía con mayúscula ("Eh, la idea…"), abría oración y la
    /// mayúscula pasa a la palabra que sigue. Fuera de eso no se toca la capitalización: Apple pone
    /// punto en las pausas pero deja minúscula cuando la frase sigue ("pero. que sean"), y
    /// capitalizar después de todo punto convertía esas pausas en cortes de oración falsos
    /// (37 de 93 dictados, auditoría del 14-sep).
    static func remove(_ pattern: String, in text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let out = NSMutableString(string: text)
        for m in re.matches(in: text, range: NSRange(location: 0, length: out.length)).reversed() {
            let removed = out.substring(with: m.range)
            out.replaceCharacters(in: m.range, with: "")
            guard removed.first?.isUppercase == true, m.range.location < out.length else { continue }
            let next = out.rangeOfComposedCharacterSequence(at: m.range.location)
            out.replaceCharacters(in: next, with: out.substring(with: next).uppercased())
        }
        return out as String
    }
}
