import Foundation

public struct Transcript: Sendable {
    public var text: String
    /// Código ISO del idioma detectado (whisper) o del locale usado (apple).
    public var language: String?
    public var engine: EngineKind
    public var elapsed: TimeInterval

    public init(text: String, language: String?, engine: EngineKind, elapsed: TimeInterval) {
        self.text = text; self.language = language; self.engine = engine; self.elapsed = elapsed
    }
}

public enum EngineKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case whisper, parakeet, apple
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .whisper: "Whisper (WhisperKit)"
        case .parakeet: "Parakeet v3 (FluidAudio)"
        case .apple: "Apple Speech"
        }
    }
    public var shortName: String {
        switch self {
        case .whisper: "Whisper"
        case .parakeet: "Parakeet"
        case .apple: "Apple"
        }
    }
}

/// Estado de preparación de un motor: descargar modelo, compilar, etc.
public enum EnginePhase: Sendable, Equatable {
    case idle
    case downloading(Double)   // 0...1
    case loading
    case ready
    case failed(String)
}

/// Contrato común. Ambos motores reciben el MISMO AudioClip y devuelven el MISMO Transcript,
/// así la app y el bench no saben cuál hay detrás.
public protocol TranscriptionEngine: Sendable {
    var kind: EngineKind { get }
    /// Descarga/carga lo que haga falta. Idempotente: si ya está listo, vuelve al tiro.
    func prepare(onPhase: @escaping @Sendable (EnginePhase) -> Void) async throws
    func transcribe(_ clip: AudioClip) async throws -> Transcript
}
