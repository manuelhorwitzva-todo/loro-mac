import ArgumentParser
import Foundation
import LoroCore

@main
struct Loro: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "loro",
        abstract: "Loro: dictado y transcripción 100% local.",
        subcommands: [Transcribe.self, Bench.self, Preview.self],
        defaultSubcommand: Transcribe.self
    )
}

struct EngineOption: ExpressibleByArgument {
    let kind: EngineKind
    init?(argument: String) {
        guard let k = EngineKind(rawValue: argument) else { return nil }
        kind = k
    }
}

func makeEngine(_ kind: EngineKind, locale: String, model: String?, language: String? = "es") -> any TranscriptionEngine {
    switch kind {
    case .whisper: WhisperEngine(model: model ?? WhisperEngine.defaultModel, language: language)
    case .parakeet: ParakeetEngine()
    case .apple: AppleSpeechEngine(locale: Locale(identifier: locale))
    }
}

func prepare(_ engine: any TranscriptionEngine) async throws {
    let lastShown = Progress5()
    try await engine.prepare { phase in
        switch phase {
        case .downloading(let p):
            let pct = Int(p * 100)
            if lastShown.advance(to: pct) { FileHandle.standardError.write("  [\(engine.kind.rawValue)] descargando modelo \(pct)%\n".data(using: .utf8)!) }
        case .loading: FileHandle.standardError.write("  [\(engine.kind.rawValue)] cargando modelo...\n".data(using: .utf8)!)
        default: break
        }
    }
}

struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Transcribe un archivo de audio.")

    @Argument(help: "Archivo de audio (wav, m4a, mp3, aiff, mp4...)") var file: String
    @Option(name: .shortAndLong, help: "whisper | apple") var engine: EngineOption = EngineOption(argument: "whisper")!
    @Option(help: "Locale para Apple Speech") var locale: String = "es_CL"
    @Option(help: "Modelo Whisper") var model: String?
    @Option(help: "Idioma principal para Whisper (es, en, auto)") var language: String = "es"

    func run() async throws {
        let clip = try AudioClip.load(url: URL(fileURLWithPath: file))
        let eng = makeEngine(engine.kind, locale: locale, model: model, language: language == "auto" ? nil : language)
        try await prepare(eng)
        let t = try await eng.transcribe(clip)
        print(t.text)
        FileHandle.standardError.write("  (\(String(format: "%.2f", t.elapsed))s, audio \(String(format: "%.1f", clip.duration))s, idioma \(t.language ?? "?"))\n".data(using: .utf8)!)
    }
}

struct Bench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Corre ambos motores sobre uno o más archivos y compara.")

    @Argument(help: "Archivos de audio") var files: [String]
    @Option(help: "Locale para Apple Speech") var locale: String = "es_CL"
    @Option(help: "Modelo Whisper") var model: String?

    func run() async throws {
        let engines: [any TranscriptionEngine] = [
            makeEngine(.whisper, locale: locale, model: model),
            makeEngine(.parakeet, locale: locale, model: nil),
            makeEngine(.apple, locale: locale, model: nil),
        ]
        for e in engines {
            do { try await prepare(e) } catch { print("  [\(e.kind.rawValue)] no disponible: \(error.localizedDescription)") }
        }
        for file in files {
            let clip = try AudioClip.load(url: URL(fileURLWithPath: file))
            print("\n== \(file)  (\(String(format: "%.1f", clip.duration))s)")
            for e in engines {
                do {
                    let t = try await e.transcribe(clip)
                    print("  \(e.kind.displayName.padding(toLength: 24, withPad: " ", startingAt: 0)) \(String(format: "%5.2f", t.elapsed))s  \(t.text)")
                } catch {
                    print("  \(e.kind.displayName.padding(toLength: 24, withPad: " ", startingAt: 0)) ERROR \(error.localizedDescription)")
                }
            }
        }
    }
}

/// Contador thread-safe para imprimir progreso de 5 en 5.
final class Progress5: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1
    func advance(to pct: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard pct / 5 != last / 5 else { return false }
        last = pct; return true
    }
}

/// Simula el preview en vivo sobre un archivo: el audio "llega" en tiempo real y se corre el
/// mismo algoritmo que DictationSession.startPreview, imprimiendo qué pasa en cada vuelta.
/// Sirve para depurar "el texto dejó de crecer" sin hablarle al micrófono.
struct Preview: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Simula el preview en vivo sobre un archivo de audio.")
    @Argument var file: String
    @Option(name: .shortAndLong) var engine: EngineOption = EngineOption(argument: "parakeet")!
    @Flag(help: "Imprimir el texto volátil completo en cada vuelta") var verbose = false

    func run() async throws {
        let clip = try AudioClip.load(url: URL(fileURLWithPath: file))
        let e = makeEngine(engine.kind, locale: "es_CL", model: nil)
        try await prepare(e)
        _ = try await e.transcribe(AudioClip(samples: Array(clip.samples.prefix(16_000))))  // calentar
        let segmenter = SpeechSegmenter()
        var committedWords: [String] = []
        var committedSampleEnd = 0
        var liveVolatile = ""
        var lastOpenDuration: TimeInterval = 0
        let t0 = Date()
        func log(_ s: String) { print(String(format: "%6.2fs  ", Date().timeIntervalSince(t0)) + s) }
        while true {
            try? await Task.sleep(for: .milliseconds(450))
            let elapsed = Date().timeIntervalSince(t0)
            let avail = min(clip.samples.count, Int(elapsed * AudioClip.sampleRate))
            let all = Array(clip.samples[..<avail])
            var committedThisPass = false
            while let b = segmenter.nextBoundary(in: all, from: committedSampleEnd) {
                committedThisPass = true
                let chunk = AudioClip(samples: Array(all[committedSampleEnd..<b.speechEnd]))
                committedSampleEnd = b.silenceEnd
                let s = Date()
                if chunk.duration >= 0.4, let t = try? await e.transcribe(chunk), !t.text.isEmpty {
                    committedWords.append(contentsOf: t.text.split(separator: " ").map(String.init))
                }
                log(String(format: "CONGELA %.1fs → %d palabras (transcribir %.2fs)", chunk.duration, committedWords.count, Date().timeIntervalSince(s)))
                lastOpenDuration = 0
            }
            let open = AudioClip(samples: Array(all[min(committedSampleEnd, all.count)...]))
            var volatile = committedThisPass ? "" : liveVolatile
            var note = "sin cambio"
            if committedThisPass || open.duration - lastOpenDuration >= 0.4 {
                lastOpenDuration = open.duration
                let s = Date()
                if open.duration >= 0.5, let t = try? await e.transcribe(open) { volatile = t.text; note = String(format: "retranscribe %.2fs", Date().timeIntervalSince(s)) }
                else if open.duration < 0.5 { volatile = ""; note = "abierto muy corto" }
            }
            liveVolatile = volatile
            log(String(format: "abierto %.1fs · %@ · volátil %d chars%@", open.duration, note, volatile.count, verbose ? "  « \(volatile)" : ""))
            if avail >= clip.samples.count { break }
        }
        print("\nCONGELADO: \(committedWords.joined(separator: " "))\nVOLÁTIL: \(liveVolatile)")
    }
}
