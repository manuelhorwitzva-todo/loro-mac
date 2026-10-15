import Foundation
@preconcurrency import WhisperKit

/// Motor Whisper vía WhisperKit (CoreML en el Neural Engine). Multilingüe con detección
/// automática de idioma, y tolera que se mezcle español e inglés en la misma frase.
public actor WhisperEngine: TranscriptionEngine {
    public nonisolated let kind: EngineKind = .whisper

    public static let defaultModel = "openai_whisper-large-v3-v20240930_turbo_632MB"
    public static let availableModels: [(id: String, label: String)] = [
        ("openai_whisper-large-v3-v20240930_turbo_632MB", "Large v3 Turbo · rápido, 632 MB"),
        ("openai_whisper-large-v3-v20240930_626MB", "Large v3 · máxima calidad, 626 MB"),
        ("distil-whisper_distil-large-v3_turbo_600MB", "Distil Large v3 Turbo · solo inglés, 600 MB"),
        ("openai_whisper-small", "Small · liviano, 200 MB"),
    ]

    private let model: String
    /// Idioma principal (código ISO, ej. "es"). nil = auto-detectar por ventana, que en
    /// dictados bilingües hace que Whisper "traduzca" al voltearse la detección.
    private let language: String?
    private let modelsDirectory: URL
    private var whisper: WhisperKit?
    private var preparing: Task<Void, Error>?

    public init(model: String = WhisperEngine.defaultModel, language: String? = "es", modelsDirectory: URL = ModelStore.whisperDirectory) {
        self.model = model
        self.language = language
        self.modelsDirectory = modelsDirectory
    }

    public func prepare(onPhase: @escaping @Sendable (EnginePhase) -> Void) async throws {
        if whisper != nil { onPhase(.ready); return }
        if let preparing { try await preparing.value; onPhase(.ready); return }
        let task = Task<Void, Error> { [model, modelsDirectory] in
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            onPhase(.downloading(0))
            let folder = try await WhisperKit.download(
                variant: model,
                downloadBase: modelsDirectory,
                progressCallback: { p in onPhase(.downloading(p.fractionCompleted)) }
            )
            onPhase(.loading)
            let config = WhisperKitConfig(modelFolder: folder.path, verbose: false, logLevel: .error, prewarm: true, load: true)
            let wk = try await WhisperKit(config)
            await self.store(wk)
            onPhase(.ready)
        }
        preparing = task
        defer { preparing = nil }
        try await task.value
    }

    private func store(_ wk: WhisperKit) { whisper = wk }

    public func transcribe(_ clip: AudioClip) async throws -> Transcript {
        guard let whisper else { throw LoroError.engine("Whisper no está preparado") }
        guard clip.duration > 0.3 else { return Transcript(text: "", language: nil, engine: .whisper, elapsed: 0) }
        let start = Date()
        var options = DecodingOptions()
        options.task = .transcribe
        options.language = language
        options.detectLanguage = language == nil
        options.temperature = 0
        options.usePrefillPrompt = true
        options.skipSpecialTokens = true
        options.withoutTimestamps = true
        // VAD corta por silencios (archivos largos van en paralelo). Probado sin VAD el 10-sep con
        // 104 dictados: arregla el único caso donde se saltaba el comienzo, pero pierde frases
        // enteras en ~8. Con VAD queda el mal menor.
        options.chunkingStrategy = .vad
        let results = try await whisper.transcribe(audioArray: clip.samples, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Transcript(text: text, language: results.first?.language, engine: .whisper, elapsed: Date().timeIntervalSince(start))
    }
}

/// Dónde viven los modelos descargados. Fuera de ~/Documents a propósito.
public enum ModelStore {
    public static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Loro", isDirectory: true)
    }
    public static var whisperDirectory: URL { root.appendingPathComponent("Models", isDirectory: true) }
}
