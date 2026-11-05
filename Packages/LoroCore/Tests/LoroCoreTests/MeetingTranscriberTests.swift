import Testing
@testable import LoroCore

@Suite struct MeetingTranscriberTests {
    /// n frames de 50 ms con el mismo nivel.
    func frames(_ n: Int, _ v: Float) -> [Float] { Array(repeating: v, count: n) }

    @Test func detectaUnTurnoConMargen() {
        let rms = frames(20, 0.001) + frames(40, 0.1) + frames(20, 0.001)
        let spans = MeetingTranscriber.speechSpans(rms: rms)
        #expect(spans.count == 1)
        #expect(abs(spans[0].start - 0.85) < 0.01)   // 1,0 s menos 0,15 de margen
        #expect(abs(spans[0].end - 3.15) < 0.01)
    }

    @Test func unePausasCortasYBotaChasquidos() {
        // 1 s de habla, 0,4 s de pausa, 1 s de habla → un turno. Un chasquido de 0,1 s → nada.
        let rms = frames(10, 0) + frames(20, 0.1) + frames(8, 0.001) + frames(20, 0.1) + frames(40, 0.001) + frames(2, 0.2) + frames(20, 0.001)
        let spans = MeetingTranscriber.speechSpans(rms: rms)
        #expect(spans.count == 1)
    }

    @Test func cortaTramosLargos() {
        let rms = frames(20 * 70, 0.1)   // 70 s sin pausa
        let spans = MeetingTranscriber.speechSpans(rms: rms)
        #expect(spans.count >= 3)
        #expect(spans.allSatisfy { $0.end - $0.start <= MeetingTranscriber.maxSpan + 0.31 })
    }

    @Test func ignoraLaVozDeLosDemasQueSeCuelaAlMicrofono() {
        // Los demás hablan de 1 a 3 s; el micrófono los oye por el parlante a la mitad del
        // nivel y 50 ms después. Después, de 5 a 7 s, habla quien graba.
        let others = frames(20, 0) + frames(40, 0.2) + frames(80, 0)
        let mic = frames(21, 0.002) + frames(40, 0.1) + frames(39, 0.002) + frames(40, 0.1)
        let spans = MeetingTranscriber.speechSpans(rms: mic, suppressWhenLouder: others)
        #expect(spans.count == 1)
        #expect(spans[0].start > 4.5)
    }

    @Test func juntaTurnosSeguidosDeLaMismaPersona() {
        let t = MeetingTranscriber.merge([
            .init(speaker: .me, start: 0, end: 2, text: "Hola."),
            .init(speaker: .me, start: 3, end: 4, text: "¿Cómo están?"),
            .init(speaker: .others, start: 4.5, end: 6, text: "Bien."),
        ])
        #expect(t.count == 2)
        #expect(t[0].text == "Hola. ¿Cómo están?")
    }
}
