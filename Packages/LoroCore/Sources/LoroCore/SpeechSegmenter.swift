import Foundation

/// Detector de pausas por energía (VAD simple) para el preview en vivo.
///
/// La idea: el texto que ya se mostró NO debe cambiar. Para eso, cada trozo de audio
/// terminado en silencio se transcribe una sola vez y se congela; el trozo en curso
/// (desde la última pausa hasta ahora) es el único que se vuelve a transcribir.
public struct SpeechSegmenter: Sendable {
    public var frameSeconds: Double = 0.05          // 50 ms por frame de energía
    public var minSilence: Double = 0.45            // pausa mínima para cortar
    public var minSpeech: Double = 0.8              // trozo mínimo para congelar
    public var maxOpen: Double = 9.0                // si no hay pausa, cortar igual
    public var floorRMS: Float = 0.004
    public var relative: Float = 0.12               // umbral = max(floor, relative * pico)

    public init() {}

    /// Busca, en `samples[from...]`, el final del próximo trozo hablado seguido de silencio.
    /// Devuelve (fin del habla, fin del silencio) en índices de sample, o nil si aún no hay.
    public func nextBoundary(in samples: [Float], from start: Int) -> (speechEnd: Int, silenceEnd: Int)? {
        let frame = Int(frameSeconds * AudioClip.sampleRate)
        guard samples.count - start >= frame * 4 else { return nil }
        var rms: [Float] = []
        var i = start
        while i + frame <= samples.count {
            var acc: Float = 0
            for j in i..<(i + frame) { acc += samples[j] * samples[j] }
            rms.append((acc / Float(frame)).squareRoot())
            i += frame
        }
        let peak = rms.max() ?? 0
        let threshold = max(floorRMS, relative * peak)
        let silenceFrames = Int(minSilence / frameSeconds)
        let minSpeechFrames = Int(minSpeech / frameSeconds)

        var speechSeen = 0
        var lastSpeechFrame = -1
        var quiet = 0
        for (f, v) in rms.enumerated() {
            if v >= threshold {
                speechSeen += 1; lastSpeechFrame = f; quiet = 0
            } else {
                quiet += 1
                if quiet >= silenceFrames, speechSeen >= minSpeechFrames, lastSpeechFrame >= 0 {
                    let speechEnd = start + (lastSpeechFrame + 1) * frame
                    let silenceEnd = start + (f + 1) * frame
                    return (speechEnd, silenceEnd)
                }
            }
        }
        // Sin pausa pero demasiado largo: cortamos en el frame más silencioso del último tercio.
        let openSeconds = Double(samples.count - start) / AudioClip.sampleRate
        if openSeconds >= maxOpen, rms.count > 10 {
            let tailStart = rms.count * 2 / 3
            var best = tailStart
            for f in tailStart..<rms.count where rms[f] < rms[best] { best = f }
            let cut = start + best * frame
            return (cut, cut)
        }
        return nil
    }
}
