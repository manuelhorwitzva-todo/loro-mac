import Foundation
import Testing
@testable import LoroCore

@Suite struct DictionaryTests {
    // Entradas propias del test (no el seed): nombres de ejemplo que se deben respetar.
    let c = DictionaryCorrector(entries: DictionaryStore.seed + [
        .term("Acme"), .term("Acme Pay"), .term("Kai"), .term("Fintual"), .term("Fintuál Plus"),
    ])

    @Test func canonicalCasing() {
        #expect(c.apply("trabajo en acme con kai") == "trabajo en Acme con Kai")
    }
    @Test func correction() {
        #expect(c.apply("lo hice con cloud code ayer") == "lo hice con Claude Code ayer")
    }
    @Test func longestFirst() {
        #expect(c.apply("la app acme pay") == "la app Acme Pay")
    }
    @Test func accentInsensitive() {
        #expect(c.apply("en fintúal") == "en Fintual")
    }
    @Test func wholeWordOnly() {
        // "caí" no debe tocarse aunque exista Kai; "loros" no es "Loro".
        #expect(c.apply("me caí y vi loros") == "me caí y vi loros")
    }
    @Test func keepsSurroundingText() {
        #expect(c.apply("¿Viste el dashboard de analytics? Sí.") == "¿Viste el dashboard de Analytics? Sí.")
    }
    @Test func multiWordWithExtraSpaces() {
        #expect(c.apply("usa test  flight hoy") == "usa TestFlight hoy")
    }
}

@Suite struct FillerFilterTests {
    let f = FillerFilter()
    @Test func standalone() {
        #expect(f.apply("eh, mándame el reporte, um, antes del viernes") == "Mándame el reporte, antes del viernes")
    }
    @Test func phrasesAreKeptByDefault() {
        // "como que" y "o sea" pueden ser contenido: por default no se tocan.
        #expect(f.apply("no sé por qué me sale como que tenéis tomada una carta") == "No sé por qué me sale como que tenéis tomada una carta")
        #expect(f.apply("O sea, mándame el reporte. Ya, nos vemos.") == "O sea, mándame el reporte. Ya, nos vemos.")
    }
    @Test func listsCanBeEnabledPerInstance() {
        var g = FillerFilter(); g.anywhere = ["como que", "you know"]; g.sentenceStarters = ["o sea", "ya"]
        #expect(g.apply("el churn como que subió, you know, bastante") == "El churn subió, bastante")
        #expect(g.apply("O sea, mándame el reporte. Ya, nos vemos.") == "Mándame el reporte. Nos vemos.")
        #expect(g.apply("mándame el reporte, o sea el de ventas") == "Mándame el reporte, o sea el de ventas")
    }
    @Test func keepsSlangAndContent() {
        #expect(f.apply("ya po weón, avísale a Kai, cachai") == "Ya po weón, avísale a Kai, cachai")
    }
    @Test func englishStarters() {
        #expect(f.apply("so we ship on Tuesday. Um, and then we watch.") == "So we ship on Tuesday. And then we watch.")
    }
    @Test func keepsAppleLowercaseAfterPause() {
        // Apple marca la pausa con punto pero deja minúscula si la frase sigue: no es un corte.
        #expect(f.apply("Dame tres opciones más, pero. que sean simples.") == "Dame tres opciones más, pero. que sean simples.")
        #expect(f.apply("Que funcione bien, ¿cachai? que no se caiga") == "Que funcione bien, ¿cachai? que no se caiga")
        #expect(f.apply("Quedó listo. Eh, la otra cosa") == "Quedó listo. La otra cosa")
    }
}

@Suite struct AudioClipTests {
    @Test func wavRoundTrip() throws {
        let samples = (0..<16_000).map { Float(sin(Double($0) * 0.05)) * 0.5 }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loro-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try AudioClip(samples: samples).write(to: url)
        let back = try AudioClip.load(url: url)
        #expect(abs(back.duration - 1.0) < 0.01)
        #expect(abs(back.samples[100] - samples[100]) < 0.001)
    }
}
