import Testing
@testable import LoroCore

/// Casos sacados de dictados reales (auditoría del 10-sep).
@Suite struct LanguageDriftTests {
    @Test func detectaInglesDeParakeet() {
        #expect(LanguageDrift.drifted("Igual imagino que estos gastos that the mayor salen como duplicados in movimiento interno, no?"))
        #expect(LanguageDrift.drifted("Creo que the scope de esta card era para quando"))
    }

    @Test func detectaItalianoDeParakeet() {
        #expect(LanguageDrift.drifted("Si yo estoy ocultando un gasto è obvio que no va a sumar"))
        #expect(LanguageDrift.drifted("y no son tanta cortes darle il contexto di lo che stiamo facendo"))
    }

    @Test func espanolConJergaTecnicaNoEsDesvio() {
        #expect(!LanguageDrift.drifted("Ya mira, necesito que me ayudes a implementar este mockup, revisa el PR y la card en TestFlight."))
        #expect(!LanguageDrift.drifted("Ve tú cómo hacerlo y qué es lo que va a hacer mejor UX, pero no me gusta el workout."))
        // Una sola ambigua no basta: "Ready for Review" es un estado del Kanban.
        #expect(!LanguageDrift.drifted("Déjala en Ready for Review"))
    }

    @Test func hasEsVerboEnEspanol() {
        #expect(!LanguageDrift.drifted("¿Has visto cómo quedó la pantalla? Has hecho un buen trabajo."))
    }
}
