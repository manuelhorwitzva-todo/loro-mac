import FluidAudio
import Foundation

/// NVIDIA Parakeet TDT 0.6B v3 vía FluidAudio (CoreML, Neural Engine). 25 idiomas europeos
/// (incluye español e inglés), muy rápido y liviano. Es el motor que el autor del video
/// original terminó prefiriendo sobre el de Apple.
public actor ParakeetEngine: TranscriptionEngine {
    public nonisolated let kind: EngineKind = .parakeet

    private var manager: AsrManager?
    private var preparing: Task<AsrManager, Error>?

    public init() {}

    public func prepare(onPhase: @escaping @Sendable (EnginePhase) -> Void) async throws {
        if manager != nil { onPhase(.ready); return }
        if let preparing { _ = try await preparing.value; onPhase(.ready); return }
        let task = Task<AsrManager, Error> {
            // FluidAudio maneja su propia carpeta (~/Library/Application Support/FluidAudio).
            onPhase(.downloading(0))
            let models = try await AsrModels.downloadAndLoad(version: .v3, encoderPrecision: .int8)
            onPhase(.loading)
            let m = AsrManager(config: .default)
            try await m.loadModels(models)
            return m
        }
        preparing = task
        defer { preparing = nil }
        let m = try await task.value
        manager = m
        onPhase(.ready)
    }

    public func transcribe(_ clip: AudioClip) async throws -> Transcript {
        guard let manager else { throw LoroError.engine("Parakeet no está preparado") }
        guard clip.duration > 0.3 else { return Transcript(text: "", language: nil, engine: .parakeet, elapsed: 0) }
        let start = Date()
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(clip.samples, decoderState: &state)
        let text = result.text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Transcript(text: text, language: nil, engine: .parakeet, elapsed: Date().timeIntervalSince(start))
    }
}
