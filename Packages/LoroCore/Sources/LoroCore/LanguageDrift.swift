import Foundation

/// Detecta cuándo un motor multilingüe se desvió de idioma en medio de un dictado en español.
///
/// Parakeet v3 no acepta forzar idioma: cuando aparece un término en inglés (UX, click,
/// command) se engancha y sigue en inglés, y a veces en italiano. Auditoría del 10-sep sobre
/// 104 audios reales: 43 se fueron al inglés ("the ventana", "in el lugar") y 22 al italiano
/// ("che è il", "non sono"). Apple (es_CL) y Whisper forzado a español no lo hacen.
///
/// La señal no son los términos técnicos —Manuel dice workout, PRs y UX hablando en español—
/// sino las palabras FUNCIONALES del inglés (artículos, conjunciones, preposiciones,
/// auxiliares). Ésas no aparecen en una frase en español salvo que el motor se haya desviado.
public enum LanguageDrift {
    /// Inequívocas: si aparece UNA en una frase en español, el motor ya se desvió.
    /// No existen en español y no se usan sueltas al hablar en chileno.
    static let strong: Set<String> = [
        "the", "and", "but", "with", "from", "that", "this", "these", "those", "there",
        "what", "when", "where", "which", "who", "why", "because", "how",
        "is", "are", "was", "were", "been", "being",
        "will", "would", "should", "could", "must",
        // "has" queda FUERA: en español es verbo ("¿has visto?").
        "have", "had", "does", "did", "done",
        "your", "his", "her", "their", "our", "they", "you", "we",
        "not", "don't", "doesn't", "didn't", "isn't", "aren't", "won't",
        "about", "after", "before", "then", "than", "also", "just", "only", "very",
        "into", "over", "under", "between", "while", "during", "here", "them",
    ]

    /// Ambiguas: aparecen legítimamente en nombres y jerga técnica que Manuel sí usa
    /// ("Reps in Reserve", "Ready for Review"), así que una sola no basta para desviar.
    static let weak: Set<String> = [
        // Nada que exista en español: "me", "no", "son", "van", "fue" quedan FUERA a propósito.
        "in", "on", "at", "to", "for", "of", "so", "as", "if", "it", "my",
        "can", "cannot", "do", "be", "am", "may", "its",
    ]

    /// Italiano: Parakeet también se desvía a esto. Solo palabras que no existen en español
    /// ("di", "e", "mi", "la" quedan fuera).
    static let italian: Set<String> = [
        "che", "il", "è", "della", "dello", "questo", "questa", "questi", "quello", "quella",
        "sono", "perché", "molto", "non", "abbiamo", "stiamo", "possiamo", "facendo",
        "gli", "nella", "nel", "anche", "voglio",
    ]

    /// Peso mínimo para dar el texto por desviado: una palabra inequívoca, o dos ambiguas.
    public static let threshold = 2

    /// Peso de un texto: 2 por palabra inequívoca (inglés o italiano), 1 por ambigua.
    public static func score(_ text: String) -> Int {
        foreignMarkers(in: text).reduce(0) { $0 + (weak.contains($1) ? 1 : 2) }
    }

    /// Palabras funcionales extranjeras encontradas, en orden de aparición (con repetidos).
    public static func foreignMarkers(in text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" })
            .map { $0.replacingOccurrences(of: "’", with: "'") }
            .filter { strong.contains($0) || weak.contains($0) || italian.contains($0) }
    }

    /// ¿Este texto, que debería estar en español, se fue a otro idioma?
    public static func drifted(_ text: String) -> Bool {
        score(text) >= threshold
    }
}
