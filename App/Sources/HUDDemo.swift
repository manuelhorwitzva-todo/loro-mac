import AppKit
import LoroKit
import SwiftUI

/// Modo de prueba del HUD: `LORO_HUD_DEMO=<carpeta> Loro`. No arma el hotkey, no abre el
/// micrófono y no pega nada: solo mueve el estado que el HUD dibuja, mide si el panel calza
/// con su contenido y deja capturas y un informe en la carpeta. Sirve para reproducir los
/// fallos visuales del HUD sin dictar de verdad.
@MainActor
enum HUDDemo {
    static var folder: URL? {
        ProcessInfo.processInfo.environment["LORO_HUD_DEMO"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private static var report: [String] = []
    private static func note(_ s: String) { report.append(s); print(s) }

    static func run(into dir: URL) async {
        let s = AppState.shared
        let hud = s.hud
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 1. Texto en vivo que crece: ¿el panel sigue al contenido?
        s.demoRecording(true)
        try? await Task.sleep(for: .milliseconds(300))
        let words = "oye que con loro en esta cajita de la captura que te voy a mandar hay veces como que se buguea como que desaparece y pasan cosas raras entonces si puedes ver cómo arreglarla y que funcione bien en general feliz por favor investígalo testéalo y revísalo con calma antes de decirme que quedó listo porque la uso todo el día".split(separator: " ").map(String.init)
        var worst: CGFloat = 0, badSamples = 0, samples = 0, shot = false
        for step in stride(from: 6, through: words.count, by: 6) {
            s.demoLive(committed: words.prefix(max(0, step - 6)).joined(separator: " "), volatile: words[max(0, step - 6)..<step].joined(separator: " "))
            if step == 24 { hud.demoSnapshot(to: dir.appendingPathComponent("1-crece-medio.png")) }
            for _ in 0..<15 {
                try? await Task.sleep(for: .milliseconds(30))
                guard let m = hud.demoMismatch() else { continue }
                samples += 1
                if abs(m) > 1 { badSamples += 1 }
                if abs(m) > abs(worst) { worst = m }
                if !shot, abs(m) > 12 { shot = true; hud.demoSnapshot(to: dir.appendingPathComponent("1-crece-descalzado.png")) }
            }
        }
        hud.demoSnapshot(to: dir.appendingPathComponent("1-crece-final.png"))
        note("1 tamaño final del panel: \(hud.demoPanel.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "?")")
        note("1 texto que crece: \(badSamples)/\(samples) muestras con el panel de otro alto que su contenido; peor diferencia \(Int(worst)) pt")

        // 2. Dictado esperando Enter + un aviso encima: ¿la cajita sigue ahí?
        s.demoRecording(false)
        s.demoPending("texto dictado que espera Enter")
        try? await Task.sleep(for: .milliseconds(400))
        hud.demoSnapshot(to: dir.appendingPathComponent("2-esperando-enter.png"))
        s.demoFlash("Reunión guardada")
        try? await Task.sleep(for: .milliseconds(500))
        hud.demoSnapshot(to: dir.appendingPathComponent("2-aviso-encima.png"))
        try? await Task.sleep(for: .seconds(3))
        note("2 aviso sobre un dictado que espera Enter: cajita visible después = \(hud.isVisible) (Enter se sigue tragando: \(s.pendingText != nil))")
        s.demoPending(nil)
        try? await Task.sleep(for: .milliseconds(300))

        // 3. Un aviso solo: ¿se lee el mensaje?
        s.demoFlash("El motor todavía no está listo")
        try? await Task.sleep(for: .milliseconds(500))
        hud.demoSnapshot(to: dir.appendingPathComponent("3-aviso-solo.png"))
        note("3 aviso solo: visible = \(hud.isVisible) (ver 3-aviso-solo.png: ¿dice el mensaje?)")
        try? await Task.sleep(for: .seconds(3))
        note("3 después de 3 s: visible = \(hud.isVisible)")

        // 4. Grabando y otra cosa deja el estado en reposo y vuelve: ¿queda del tamaño correcto al reaparecer?
        s.demoRecording(true)
        s.demoLive(committed: words.prefix(30).joined(separator: " "), volatile: "")
        try? await Task.sleep(for: .milliseconds(900))
        s.demoRecording(false)
        try? await Task.sleep(for: .milliseconds(300))
        s.demoRecording(true)
        try? await Task.sleep(for: .milliseconds(120))
        note("4 reaparece tras esconderse: diferencia de alto al mostrarse = \(Int(hud.demoMismatch() ?? -999)) pt")
        hud.demoSnapshot(to: dir.appendingPathComponent("4-reaparece.png"))
        s.demoRecording(false)

        try? await Task.sleep(for: .milliseconds(300))

        // 5. Segundo toque mientras el micrófono todavía abre: la cajita no se debe ir.
        s.demoMicStarting(true)
        try? await Task.sleep(for: .milliseconds(300))
        s.startRecording()
        try? await Task.sleep(for: .milliseconds(300))
        note("5 segundo toque con el micrófono abriendo: cajita visible = \(hud.isVisible), sigue abriendo = \(s.micStarting)")
        hud.demoSnapshot(to: dir.appendingPathComponent("5-abriendo-microfono.png"))
        s.demoMicStarting(false)

        // 6. Un aviso mientras se graba: al irse el aviso la cajita sigue.
        s.demoRecording(true)
        s.demoFlash("Reunión guardada")
        try? await Task.sleep(for: .seconds(3))
        note("6 aviso mientras se graba: cajita visible después = \(hud.isVisible)")
        s.demoRecording(false)
        try? await Task.sleep(for: .milliseconds(300))
        note("6 al terminar: cajita visible = \(hud.isVisible)")

        // 7. Reglas puras.
        var ok = true
        func check(_ c: Bool, _ what: String) { if !c { ok = false; note("   FALLA regla: \(what)") } }
        check(!HUDRule.visible(micStarting: false, status: .idle, pending: false, message: false), "en reposo no se ve")
        check(!HUDRule.visible(micStarting: false, status: .error("x"), pending: false, message: false), "un error ya avisado no la deja pegada")
        check(!HUDRule.visible(micStarting: false, status: .preparing("x"), pending: false, message: false), "preparar el motor no la muestra")
        check(HUDRule.visible(micStarting: true, status: .idle, pending: false, message: false), "abriendo micrófono se ve")
        check(HUDRule.visible(micStarting: false, status: .recording, pending: false, message: false), "grabando se ve")
        check(HUDRule.visible(micStarting: false, status: .transcribing, pending: false, message: false), "transcribiendo se ve")
        check(HUDRule.visible(micStarting: false, status: .idle, pending: true, message: false), "esperando Enter se ve")
        check(HUDRule.visible(micStarting: false, status: .idle, pending: false, message: true), "un aviso se ve")
        check(HUDRule.showsMessage(micStarting: false, status: .idle, pending: false, message: true), "aviso solo ocupa el título")
        check(!HUDRule.showsMessage(micStarting: false, status: .recording, pending: false, message: true), "aviso no tapa la grabación")
        check(!HUDRule.showsMessage(micStarting: false, status: .idle, pending: true, message: true), "aviso no tapa el Enter pendiente")
        check(HUDRule.keepsRecordingAfterEarlyRelease(heldFor: 0.15), "toque corto sigue grabando")
        check(!HUDRule.keepsRecordingAfterEarlyRelease(heldFor: 1.2), "presión larga ya soltada se cierra")
        note("7 reglas puras: \(ok ? "13/13 bien" : "HAY FALLAS")")

        try? report.joined(separator: "\n").write(to: dir.appendingPathComponent("informe.txt"), atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}
