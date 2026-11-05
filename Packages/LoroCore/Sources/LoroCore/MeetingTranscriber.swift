@preconcurrency import AVFoundation
import Foundation

/// Arma la transcripción de una reunión desde sus dos pistas: corta cada pista en turnos de
/// habla (por energía), transcribe cada turno y los ordena por hora. Quién habló sale de la
/// pista, no de un modelo: "tú" es el micrófono, "otros" es el audio del navegador.
///
/// Es el respaldo local. La transcripción "oficial" la puede hacer el sistema al que se manda el audio.
public struct MeetingTranscriber: Sendable {
    public enum Speaker: String, Sendable, Codable { case me, others }

    public struct Turn: Sendable, Codable, Equatable {
        public var speaker: Speaker
        public var start: TimeInterval
        public var end: TimeInterval
        public var text: String
    }

    /// Un tramo con habla, en segundos desde el inicio de la grabación.
    public struct Span: Sendable, Equatable { public var start: Double; public var end: Double }

    static let frameSeconds = 0.05
    /// Tope por trozo: los motores rinden mejor con trozos cortos y Parakeet se degrada en largos.
    static let maxSpan = 28.0

    public init() {}

    /// Energía RMS por frame de 50 ms, leyendo el archivo por bloques.
    public static func frameRMS(of url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        let frame = AVAudioFrameCount(fmt.sampleRate * frameSeconds)
        let chunk = frame * 200
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { return [] }
        var out: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buf, frameCount: chunk)
            let n = Int(buf.frameLength)
            if n == 0 { break }
            let p = buf.floatChannelData![0]
            var i = 0
            while i < n {
                let end = min(i + Int(frame), n)
                var acc: Float = 0
                for j in i..<end { acc += p[j] * p[j] }
                out.append((acc / Float(end - i)).squareRoot())
                i = end
            }
        }
        return out
    }

    /// Tramos con habla. `suppress`: frames donde la otra pista suena más fuerte (la voz de los
    /// demás que se cuela por el parlante al micrófono) se tratan como silencio en esta pista.
    public static func speechSpans(rms: [Float], suppressWhenLouder other: [Float]? = nil) -> [Span] {
        guard !rms.isEmpty else { return [] }
        var energy = rms
        if let other, !other.isEmpty {
            // La voz que sale por el parlante llega al micrófono un poco después y con eco: se
            // compara contra lo más fuerte de la otra pista en una ventana de -400 ms a +100 ms.
            // Medido el 5-nov con el parlante del Mac: el micrófono recibe la voz de los demás
            // a 0,4-0,8 veces el nivel con que llega por la llamada, 50 ms después.
            for i in energy.indices {
                let lo = max(0, i - 8), hi = min(other.count - 1, i + 2)
                guard lo <= hi else { continue }
                var peak: Float = 0
                for j in lo...hi where other[j] > peak { peak = other[j] }
                if peak > 0.01 && energy[i] < peak { energy[i] = 0 }
            }
        }
        // Umbral relativo al ruido de fondo de ESTA pista (percentil 20), con un piso fijo.
        let sorted = energy.filter { $0 > 0 }.sorted()
        let noise = sorted.isEmpty ? 0 : sorted[sorted.count / 5]
        // Con tope: si alguien habla casi sin pausas (una presentación), el percentil 20 ya es
        // voz y el umbral quedaría por encima de ella. La voz rara vez baja de 0,02 RMS.
        let threshold = max(Float(0.006), min(noise * 3, 0.015))

        var raw: [(Int, Int)] = []
        var startF: Int?
        for (i, v) in energy.enumerated() {
            if v >= threshold { if startF == nil { startF = i } } else if let s = startF { raw.append((s, i)); startF = nil }
        }
        if let s = startF { raw.append((s, energy.count)) }

        // Une pausas cortas (respirar entre frases) y bota chasquidos sueltos.
        let maxGap = Int(0.6 / frameSeconds), minLen = Int(0.4 / frameSeconds)
        var merged: [(Int, Int)] = []
        for r in raw {
            if let last = merged.last, r.0 - last.1 <= maxGap { merged[merged.count - 1].1 = r.1 } else { merged.append(r) }
        }
        merged = merged.filter { $0.1 - $0.0 >= minLen }

        // Corta los tramos largos en el frame más silencioso entre 15 y 28 s.
        let maxF = Int(maxSpan / frameSeconds), minCut = Int(15 / frameSeconds)
        var spans: [Span] = []
        for var (s, e) in merged {
            while e - s > maxF {
                var cut = s + minCut
                for f in (s + minCut)..<(s + maxF) where energy[f] < energy[cut] { cut = f }
                spans.append(Span(start: Double(s) * frameSeconds, end: Double(cut) * frameSeconds))
                s = cut
            }
            spans.append(Span(start: Double(s) * frameSeconds, end: Double(e) * frameSeconds))
        }
        // Un poco de margen para no comerse el inicio o el final de una palabra.
        let total = Double(energy.count) * frameSeconds
        return spans.map { Span(start: max(0, $0.start - 0.15), end: min(total, $0.end + 0.15)) }
    }

    /// Lee un tramo de un archivo y lo deja en el formato de los motores (16 kHz mono).
    public static func clip(from url: URL, span: Span) throws -> AudioClip {
        let file = try AVAudioFile(forReading: url)
        let sr = file.processingFormat.sampleRate
        let start = AVAudioFramePosition(span.start * sr)
        let count = AVAudioFrameCount(max(0, (span.end - span.start) * sr))
        guard start < file.length, count > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { return AudioClip(samples: []) }
        file.framePosition = start
        try file.read(into: buf, frameCount: count)
        return try AudioClip.resample(buf)
    }

    /// Transcribe la reunión. `transcribe` recibe un trozo y devuelve su texto (o nil).
    /// `progress` va de 0 a 1.
    public func transcribe(mic: URL, system: URL,
                           transcribe: @Sendable (AudioClip) async -> String?,
                           progress: @Sendable (Double) -> Void = { _ in }) async throws -> [Turn] {
        let micRMS = try Self.frameRMS(of: mic)
        let sysRMS = try Self.frameRMS(of: system)
        let jobs = Self.speechSpans(rms: micRMS, suppressWhenLouder: sysRMS).map { (Speaker.me, $0, mic) }
                 + Self.speechSpans(rms: sysRMS).map { (Speaker.others, $0, system) }
        let ordered = jobs.sorted { $0.1.start < $1.1.start }
        var turns: [Turn] = []
        for (i, job) in ordered.enumerated() {
            progress(Double(i) / Double(max(ordered.count, 1)))
            let clip = try Self.clip(from: job.2, span: job.1)
            guard clip.duration > 0.3, let text = await transcribe(clip)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { continue }
            turns.append(Turn(speaker: job.0, start: job.1.start, end: job.1.end, text: text))
        }
        progress(1)
        return Self.merge(turns)
    }

    /// Junta turnos seguidos de la misma persona (separados por menos de 2 s) en un párrafo.
    public static func merge(_ turns: [Turn]) -> [Turn] {
        var out: [Turn] = []
        for t in turns.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, last.speaker == t.speaker, t.start - last.end < 2 {
                out[out.count - 1].end = t.end
                out[out.count - 1].text += " " + t.text
            } else {
                out.append(t)
            }
        }
        return out
    }

    public static func markdown(_ turns: [Turn], title: String, started: Date, duration: TimeInterval,
                                meName: String, othersName: String = "Otros", engine: String) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "es_CL")
        df.dateFormat = "d 'de' MMMM yyyy, HH:mm"
        var md = "# \(title)\n\n\(df.string(from: started)) · \(Self.clock(duration)) · transcrito en este Mac con \(engine)\n\n"
        if turns.isEmpty { md += "_No se detectó habla en ninguna de las dos pistas._\n" }
        for t in turns {
            md += "**[\(Self.clock(t.start))] \(t.speaker == .me ? meName : othersName):** \(t.text)\n\n"
        }
        return md
    }

    public static func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }
}
