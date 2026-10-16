import AVFoundation
import Foundation
import LoroCore
import os

let kitLog = Logger(subsystem: "cl.manulit0.loro", category: "dictation")

/// Cada etapa por la que pasa el texto, para auditar qué aporta cada una.
public struct DictationStages: Sendable, Equatable, Codable {
    /// Tal cual salió del motor.
    public var raw: String
    /// Tras el diccionario personal.
    public var dictionary: String
    /// Tras el filtro determinista de muletillas.
    public var filler: String
    /// Qué etapa se entregó: "dictionary" o "filler".
    public var delivered: String
    /// Si Parakeet se desvió de idioma y hubo que re-transcribir con Whisper, acá queda
    /// lo que había dicho el primero. Sirve para auditar el fallback (nil si no hubo).
    public var driftedRaw: String? = nil
}

/// Resultado de un dictado o de un archivo transcrito.
public struct DictationResult: Sendable, Equatable {
    public var id = UUID()
    public var text: String
    public var stages: DictationStages
    public var engine: EngineKind
    public var audioDuration: TimeInterval
    public var elapsed: TimeInterval
    public var started: Date
    public var source: String
    /// El audio tal cual se transcribió. La app decide si lo guarda (auditoría) o lo bota.
    public var clip: AudioClip? = nil

    public init(id: UUID = UUID(), text: String, stages: DictationStages, engine: EngineKind,
                audioDuration: TimeInterval, elapsed: TimeInterval, started: Date, source: String, clip: AudioClip? = nil) {
        self.id = id; self.text = text; self.stages = stages; self.engine = engine
        self.audioDuration = audioDuration; self.elapsed = elapsed
        self.started = started; self.source = source; self.clip = clip
    }
}

/// El pipeline completo de dictado, sin UI: motores, micrófono, preview en vivo por
/// segmentos, diccionario y filtro de muletillas. Loro y Nido usan exactamente esta clase; cada app
/// decide qué hacer con el texto (Loro lo pega, Nido lo escribe en su PTY).
///
/// Los callbacks llegan en el MainActor.
@MainActor
public final class DictationSession {
    public enum Status: Equatable, Sendable {
        case idle, preparing(String), recording, transcribing
        case error(String)

        public var label: String {
            switch self {
            case .idle: "Listo"
            case .preparing(let s): s
            case .recording: "Escuchando…"
            case .transcribing: "Transcribiendo…"
            case .error(let e): e
            }
        }
    }

    // MARK: Callbacks
    public var onStatus: ((Status) -> Void)?
    public var onEnginePhase: ((EnginePhase) -> Void)?
    public var onLevel: ((Float) -> Void)?
    /// Texto en vivo: `committed` ya no cambia; `volatile` puede seguir corrigiéndose.
    public var onLive: ((_ committed: String, _ volatile: String) -> Void)?

    // MARK: Estado
    public private(set) var status: Status = .idle { didSet { if status != oldValue { onStatus?(status) } } }
    public private(set) var enginePhase: EnginePhase = .idle { didSet { if enginePhase != oldValue { onEnginePhase?(enginePhase) } } }
    public private(set) var liveCommitted = ""
    public private(set) var liveVolatile = ""

    /// Config y diccionario se leen en cada uso: la app dueña puede cambiarlos en caliente.
    public var settings: () -> LoroSettings
    public var corrector: () -> DictionaryCorrector

    private let recorder = MicRecorder()
    private let media = MediaPause()
    private let fillerFilter = FillerFilter()
    private let segmenter = SpeechSegmenter()
    private var engines: [EngineKind: any TranscriptionEngine] = [:]
    private var prepareTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var fallbackPrepareTask: Task<Void, Never>?
    private var recordingStart: Date?
    private var starting = false
    private var committedWords: [String] = []
    private var committedSampleEnd = 0

    public init(settings: @escaping () -> LoroSettings, corrector: @escaping () -> DictionaryCorrector) {
        self.settings = settings
        self.corrector = corrector
    }

    public var isRecording: Bool { status == .recording }
    public var isReady: Bool { enginePhase == .ready }

    // MARK: - Motores

    private func engine(for kind: EngineKind) -> any TranscriptionEngine {
        if let e = engines[kind] { return e }
        let s = settings()
        let e: any TranscriptionEngine = switch kind {
        case .whisper: WhisperEngine(model: s.whisperModel, language: s.whisperLanguage == "auto" ? nil : s.whisperLanguage)
        case .parakeet: ParakeetEngine()
        case .apple: AppleSpeechEngine(locale: Locale(identifier: s.appleLocale))
        }
        engines[kind] = e
        return e
    }

    /// Descarta un motor cacheado (cuando cambia su modelo o idioma) y vuelve a preparar.
    public func invalidateEngine(_ kind: EngineKind) {
        engines[kind] = nil
        if kind == .whisper { fallbackPrepareTask?.cancel(); fallbackPrepareTask = nil }
    }

    /// Prepara el motor configurado (descarga y compila si hace falta). Idempotente.
    public func prepareEngine() {
        prepareTask?.cancel()
        let kind = settings().engine
        let e = engine(for: kind)
        prepareTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            enginePhase = .loading
            status = .preparing("Preparando \(kind.displayName)…")
            kitLog.info("preparando motor \(kind.rawValue, privacy: .public)")
            do {
                try await e.prepare { phase in
                    Task { @MainActor in
                        kitLog.info("motor \(kind.rawValue, privacy: .public): \(String(describing: phase), privacy: .public)")
                        self.enginePhase = phase
                        switch phase {
                        case .downloading(let p): self.status = .preparing("Descargando modelo \(Int(p * 100))%")
                        case .loading: self.status = .preparing("Compilando modelo para el Neural Engine (solo la primera vez, unos minutos)")
                        default: break
                        }
                    }
                }
                enginePhase = .ready
                kitLog.info("motor \(kind.rawValue, privacy: .public) listo")
                if case .preparing = status { status = .idle }
                prepareFallbackEngine(main: kind)
            } catch {
                kitLog.error("motor \(kind.rawValue, privacy: .public) falló: \(error.localizedDescription, privacy: .public)")
                enginePhase = .failed(error.localizedDescription)
                status = .error(error.localizedDescription)
            }
        }
    }

    /// Deja Whisper cargado en segundo plano para que el fallback de Parakeet no
    /// cueste una eternidad. Medido el 8-sep: cargarlo en frío tarda ~3 minutos (compila para
    /// el Neural Engine); en caliente, ~1 s por dictado. Como el fallback ocurre justo cuando
    /// el usuario espera su texto, se paga antes y no en el momento.
    private func prepareFallbackEngine(main kind: EngineKind) {
        guard kind == .parakeet, fallbackPrepareTask == nil else { return }
        let w = engine(for: .whisper)
        // .utility y no .background: con background macOS lo posterga tanto que en Nido tardó
        // más de 6 minutos (medido el 8-sep con `sample`: seguía dentro de MLModel.load).
        fallbackPrepareTask = Task(priority: .utility) {
            do {
                try await w.prepare { _ in }
                kitLog.info("Whisper precargado para el fallback")
            } catch {
                kitLog.notice("no se pudo precargar Whisper: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Grabación

    /// Abre el micrófono y arranca el preview. Devuelve false si no se pudo (motor no listo, error).
    @discardableResult
    public func start() async -> Bool {
        guard status == .idle || { if case .error = status { return true } else { return false } }() else { return false }
        guard enginePhase == .ready else {
            kitLog.notice("start() con el motor no listo (\(String(describing: self.enginePhase), privacy: .public))")
            status = .preparing("El motor todavía no está listo")
            return false
        }
        // Pausar la música y abrir el micrófono toma ~0,3 s con el estado todavía en idle: un
        // segundo toque entremedio no debe abrir otra grabación encima.
        guard !starting else { return false }
        starting = true
        defer { starting = false }
        // La música se pausa ANTES de abrir el micrófono: abrir el de un audífono Bluetooth lo pasa
        // a manos libres, y si la música sigue sonando se escucha como llamada telefónica.
        await media.pause()
        do {
            try await recorder.start(voiceIsolation: settings().voiceIsolation,
                                     preferBuiltInMic: UserDefaults.standard.bool(forKey: Self.builtInMicKey)) { [weak self] lvl in
                Task { @MainActor in self?.onLevel?(lvl) }
            }
            recordingStart = Date()
            let mode = AVCaptureDevice.preferredMicrophoneMode
            kitLog.info("grabando, modo de micrófono del sistema: \(Self.micModeName(mode), privacy: .public)")
            resetPreview()
            status = .recording
            startPreview()
            return true
        } catch {
            media.resume()
            status = .error(error.localizedDescription)
            return false
        }
    }

    public func cancel() {
        guard status == .recording else { return }
        previewTask?.cancel()
        Task { _ = await recorder.stop(); media.resume() }
        onLevel?(0)
        resetPreview()
        status = .idle
    }

    /// Cierra el micrófono y transcribe todo. nil si fue demasiado corto o falló.
    public func finish() async -> DictationResult? {
        guard status == .recording else { return nil }
        let started = recordingStart ?? Date()
        previewTask?.cancel()
        let clip = await recorder.stop()
        media.resume()
        onLevel?(0)
        guard clip.duration >= 0.5 else {
            kitLog.notice("grabación demasiado corta (\(clip.duration, format: .fixed(precision: 2))s), descartada")
            resetPreview()
            status = .idle
            return nil
        }
        return await transcribe(clip, source: "Dictado", started: started)
    }

    /// Camino común para dictado y archivos: transcribe, diccionario, muletillas.
    public func transcribe(_ clip: AudioClip, source: String, started: Date = Date()) async -> DictationResult? {
        status = .transcribing
        let corrector = corrector()
        let s = settings()
        do {
            let e = engine(for: s.engine)
            try await e.prepare { _ in }
            var transcript = try await e.transcribe(clip)
            var raw = transcript.text
            var driftedRaw: String? = nil
            // Parakeet no acepta forzar idioma y se engancha al inglés (o al italiano) cuando el
            // dictado trae términos en inglés. Whisper sí va forzado a español: si detectamos el
            // desvío, re-transcribimos con él. Apple no lo necesita: va fijo en un locale.
            if s.engine == .parakeet, !raw.isEmpty, LanguageDrift.drifted(raw) {
                let markers = LanguageDrift.foreignMarkers(in: raw)
                kitLog.notice("parakeet se desvió de idioma (\(markers.joined(separator: " "), privacy: .public)) → re-transcribiendo con Whisper")
                let w = engine(for: .whisper)
                if (try? await w.prepare { _ in }) != nil, let t2 = try? await w.transcribe(clip), !t2.text.isEmpty {
                    driftedRaw = raw
                    transcript = t2
                    raw = t2.text
                }
            }
            let afterDictionary = corrector.apply(raw)
            let afterFiller = s.fillerFilter ? fillerFilter.apply(afterDictionary) : afterDictionary
            let stages = DictationStages(raw: raw, dictionary: afterDictionary, filler: afterFiller,
                                         delivered: s.fillerFilter ? "filler" : "dictionary", driftedRaw: driftedRaw)
            let text = afterFiller
            kitLog.info("\(source, privacy: .public): \(clip.duration, format: .fixed(precision: 1))s de audio (nivel \(clip.rms, format: .fixed(precision: 4))) → \(text.count) caracteres con \(transcript.engine.rawValue, privacy: .public) en \(transcript.elapsed, format: .fixed(precision: 2))s")
            resetPreview()
            status = .idle
            let result = DictationResult(text: text, stages: stages, engine: transcript.engine, audioDuration: clip.duration,
                                         elapsed: transcript.elapsed, started: started, source: source, clip: clip)
            return result
        } catch {
            resetPreview()
            kitLog.error("\(source, privacy: .public) falló: \(error.localizedDescription, privacy: .public)")
            status = .error(error.localizedDescription)
            return nil
        }
    }

    /// Vuelve a transcribir un audio ya guardado con el motor que se le pida (típicamente
    /// Whisper, que va forzado a español). Devuelve el texto pasado por diccionario y filtro,
    /// igual que un dictado nuevo, pero SIN tocar historial ni estadísticas: de eso se encarga
    /// quien llama. nil si el motor falla o no saca nada.
    public func retranscribe(_ clip: AudioClip, with kind: EngineKind) async -> (text: String, stages: DictationStages)? {
        let s = settings()
        let corrector = corrector()
        status = .transcribing
        defer { status = .idle }
        let e = engine(for: kind)
        guard (try? await e.prepare { _ in }) != nil, let t = try? await e.transcribe(clip), !t.text.isEmpty else {
            kitLog.error("re-transcribir con \(kind.rawValue, privacy: .public) falló")
            return nil
        }
        let afterDictionary = corrector.apply(t.text)
        let afterFiller = s.fillerFilter ? fillerFilter.apply(afterDictionary) : afterDictionary
        let stages = DictationStages(raw: t.text, dictionary: afterDictionary, filler: afterFiller,
                                     delivered: s.fillerFilter ? "filler" : "dictionary")
        kitLog.info("re-transcrito con \(kind.rawValue, privacy: .public): \(afterFiller.count) caracteres")
        return (afterFiller, stages)
    }

    // MARK: - Preview en vivo

    /// Cada ~0.45 s: si apareció una pausa, congela ese trozo (se transcribe UNA vez y no
    /// cambia más); y retranscribe solo el trozo abierto, que es el único que se mueve.
    private func startPreview() {
        previewTask?.cancel()
        let e = engine(for: settings().engine)
        previewTask = Task { [weak self] in
            var lastOpenDuration: TimeInterval = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(450))
                guard let self, !Task.isCancelled, status == .recording else { return }
                let all = await recorder.snapshot().samples

                var committedThisPass = false
                while let b = segmenter.nextBoundary(in: all, from: committedSampleEnd) {
                    committedThisPass = true
                    let chunk = AudioClip(samples: Array(all[committedSampleEnd..<b.speechEnd]))
                    committedSampleEnd = b.silenceEnd
                    if chunk.duration >= 0.4, let t = try? await e.transcribe(chunk), !t.text.isEmpty {
                        committedWords.append(contentsOf: t.text.split(separator: " ").map(String.init))
                    }
                    guard !Task.isCancelled, status == .recording else { return }
                    lastOpenDuration = 0
                }

                let open = AudioClip(samples: Array(all[min(committedSampleEnd, all.count)...]))
                var volatile = committedThisPass ? "" : liveVolatile
                if committedThisPass || open.duration - lastOpenDuration >= 0.4 {
                    lastOpenDuration = open.duration
                    if open.duration >= 0.5, let t = try? await e.transcribe(open) { volatile = t.text }
                    else if open.duration < 0.5 { volatile = "" }
                }
                guard !Task.isCancelled, status == .recording else { return }
                let c = corrector()
                liveCommitted = c.apply(committedWords.joined(separator: " "))
                liveVolatile = c.apply(volatile)
                onLive?(liveCommitted, liveVolatile)
                kitLog.info("preview: \(self.committedWords.count) palabras congeladas, abierto \(open.duration, format: .fixed(precision: 1))s")
            }
        }
    }

    private func resetPreview() {
        liveCommitted = ""; liveVolatile = ""
        committedWords = []; committedSampleEnd = 0
        onLive?("", "")
    }

    // MARK: - Utilidades

    /// UserDefaults: true para dictar con el micrófono del Mac aunque haya audífonos Bluetooth.
    /// Por default se usa el micrófono conectado (el del audífono, que capta mejor con ruido).
    public static let builtInMicKey = "preferBuiltInMic"

    public static func micModeName(_ m: AVCaptureDevice.MicrophoneMode) -> String {
        switch m {
        case .standard: "Estándar"
        case .voiceIsolation: "Aislamiento de voz"
        case .wideSpectrum: "Espectro amplio"
        @unknown default: "Desconocido"
        }
    }

    /// Abre el micrófono sin transcribir, para que aparezca el selector de modo de micrófono
    /// de macOS (solo se muestra con el mic activo). Llama a `endMicModeSelection` al terminar.
    public func beginMicModeSelection() async throws {
        guard status == .idle else { return }
        try await recorder.start(voiceIsolation: false) { [weak self] lvl in Task { @MainActor in self?.onLevel?(lvl) } }
        try? await Task.sleep(for: .milliseconds(300))
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
    }

    public func endMicModeSelection() {
        Task { _ = await recorder.stop(); onLevel?(0) }
        kitLog.info("modo de micrófono elegido: \(Self.micModeName(AVCaptureDevice.preferredMicrophoneMode), privacy: .public)")
    }
}
