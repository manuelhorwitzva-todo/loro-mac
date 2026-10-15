@preconcurrency import AVFoundation
import Foundation
import Speech

/// Motor de Apple (SpeechAnalyzer, macOS 26). Cero descargas grandes, cero dependencias,
/// pero trabaja con UN locale por sesión: no mezcla idiomas dentro de una misma frase.
public actor AppleSpeechEngine: TranscriptionEngine {
    public nonisolated let kind: EngineKind = .apple
    public let locale: Locale
    private var ready = false

    public init(locale: Locale = Locale(identifier: "es_CL")) {
        self.locale = locale
    }

    public static var supportedLocales: [Locale] {
        get async { await SpeechTranscriber.supportedLocales }
    }

    public func prepare(onPhase: @escaping @Sendable (EnginePhase) -> Void) async throws {
        if ready { onPhase(.ready); return }
        guard SpeechTranscriber.isAvailable else { throw LoroError.unavailable("Apple Speech no está disponible en este Mac") }
        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw LoroError.unavailable("Apple Speech no soporta \(locale.identifier)")
        }
        let transcriber = SpeechTranscriber(locale: resolved, preset: .transcription)
        // Si el modelo del idioma no está instalado (ej. en_US), lo baja el sistema.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onPhase(.downloading(0))
            let progress = request.progress
            let observer = Task {
                while !Task.isCancelled {
                    onPhase(.downloading(progress.fractionCompleted))
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            defer { observer.cancel() }
            try await request.downloadAndInstall()
        }
        onPhase(.loading)
        ready = true
        onPhase(.ready)
    }

    public func transcribe(_ clip: AudioClip) async throws -> Transcript {
        guard ready else { throw LoroError.engine("Apple Speech no está preparado") }
        guard clip.duration > 0.3 else { return Transcript(text: "", language: locale.identifier, engine: .apple, elapsed: 0) }
        let start = Date()
        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw LoroError.unavailable("Apple Speech no soporta \(locale.identifier)")
        }
        let transcriber = SpeechTranscriber(locale: resolved, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Recolectamos los resultados en paralelo a la alimentación de audio.
        let collector = Task<String, Error> {
            var parts: [String] = []
            for try await result in transcriber.results {
                parts.append(String(result.text.characters))
            }
            return parts.joined(separator: " ")
        }

        // El analizador puede pedir un formato distinto a 16 kHz; lo respetamos.
        let wanted = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) ?? AudioClip.canonicalFormat
        let buffer = try Self.convert(clip.pcmBuffer(), to: wanted)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()

        try await analyzer.prepareToAnalyze(in: wanted)
        _ = try await analyzer.analyzeSequence(stream)
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        let text = try await collector.value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Transcript(text: text, language: resolved.identifier, engine: .apple, elapsed: Date().timeIntervalSince(start))
    }

    private static func convert(_ input: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if input.format == format { return input }
        guard let converter = AVAudioConverter(from: input.format, to: format) else {
            throw LoroError.audio("No hay conversor hacia \(format)")
        }
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw LoroError.audio("No pude reservar buffer")
        }
        var consumed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true; status.pointee = .haveData; return input
        }
        if let err { throw err }
        return out
    }
}
