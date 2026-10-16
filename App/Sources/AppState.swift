import AppKit
import AVFoundation
import Foundation
import LoroCore
import LoroKit
import Observation
import os

let log = Logger(subsystem: "cl.manulit0.loro", category: "dictation")

/// El cerebro de la app: dueño de los motores, del grabador, del hotkey y del historial.
/// @MainActor porque todo lo que observa la UI vive aquí.
@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    typealias Status = DictationSession.Status

    typealias HistoryItem = StoredDictation

    var settings: LoroSettings { didSet { settings.save(); applySettings(from: oldValue) } }
    var status: Status = .idle
    var level: Float = 0
    /// Texto provisorio que se muestra mientras hablas. Se reemplaza por el final al soltar.
    var liveText: String = ""
    /// Parte del preview ya "congelada": palabras que dos previews seguidos sacaron iguales.
    /// Así lo que ya dijiste deja de moverse y solo cambia la cola reciente.
    var liveCommitted: String = ""
    var liveVolatile: String = ""
    /// Copias en memoria para la UI. La fuente de verdad es el disco, porque Nido también
    /// escribe ahí: se mutan SOLO vía `HistoryStore` y se recargan con `reloadHistory()`.
    private(set) var history: [StoredDictation] = HistoryStore.loadHistory()
    private(set) var stats: LoroStats = HistoryStore.loadStats()
    var enginePhase: EnginePhase = .idle
    /// Dictado listo esperando Enter (modo confirmar). Ya está en el portapapeles.
    var pendingText: String?
    var hasAccessibility = HotkeyMonitor.hasAccessibility
    var hasMicrophone = false
    var dictionary: [DictionaryEntry] = DictionaryStore.load() {
        didSet {
            try? DictionaryStore.save(dictionary)
            corrector = DictionaryCorrector(entries: dictionary)
        }
    }
    private(set) var corrector = DictionaryCorrector(entries: DictionaryStore.load())
    var lastTranscript: String = ""
    /// Campo de prueba de la ventana de Inicio.
    var scratchText: String = ""

    private let hotkey = HotkeyMonitor()
    /// El pipeline de dictado vive en LoroKit (compartido con Nido). AppState solo lo observa
    /// y decide qué hacer con el texto: pegar, guardar historial, mostrar HUD.
    let session: DictationSession
    /// Si la tecla ya se soltó mientras el micrófono todavía arrancaba, cerramos al tiro.
    private var hotkeyIsDown = false
    private var hotkeyPressedAt = Date.distantPast
    /// Modo híbrido: la grabación la abrió un toque corto, así que la cierra el próximo toque.
    private var recordingStartedByTap = false
    /// Entre que se aprieta el atajo y el micrófono empieza a entregar audio.
    var micStarting = false
    let hud = HUDController()

    private init() {
        let initial = LoroSettings.load()
        settings = initial
        session = DictationSession(settings: { initial }, corrector: { DictionaryCorrector(entries: []) })
        session.settings = { [unowned self] in self.settings }
        session.corrector = { [unowned self] in self.corrector }
        session.onStatus = { [weak self] st in
            guard let self else { return }
            status = st
            switch st {
            case .recording, .transcribing: hud.show()
            case .idle: hud.hide()
            case .error(let e): hud.flash(e)
            case .preparing(let m): if hud.isVisible { hud.flash(m) }
            }
        }
        session.onEnginePhase = { [weak self] p in self?.enginePhase = p }
        session.onLevel = { [weak self] l in self?.level = l }
        session.onLive = { [weak self] c, v in
            guard let self else { return }
            liveCommitted = c; liveVolatile = v
            liveText = v.isEmpty ? c : (c.isEmpty ? v : c + " " + v)
        }
    }

    // MARK: - Arranque

    func boot() async {
        hasMicrophone = await MicRecorder.requestPermission()
        if !settings.onboardingDone {
            NotificationCenter.default.post(name: .loroOpenMain, object: nil)
        }
        Task { [weak self] in
            while let self {
                try? await Task.sleep(for: .seconds(5))
                hasMicrophone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                reloadHistoryIfChanged()
            }
        }
        if !HotkeyMonitor.hasAccessibility { HotkeyMonitor.requestAccessibility() }
        startHotkey()
        prepareCurrentEngine()
        // Reintenta enganchar el hotkey cuando el usuario concede Accesibilidad sin reiniciar.
        Task { [weak self] in
            while let self, !hasAccessibility {
                try? await Task.sleep(for: .seconds(2))
                hasAccessibility = HotkeyMonitor.hasAccessibility
                if hasAccessibility { startHotkey() }
            }
        }
    }

    private func startHotkey() {
        hotkey.onPress = { [weak self] in self?.hotkeyPressed() }
        hotkey.onRelease = { [weak self] in self?.hotkeyReleased() }
        hotkey.onEscape = { [weak self] in
            guard let self else { return }
            pendingText != nil ? discardPending() : cancelRecording()
        }
        hotkey.onReturn = { [weak self] in
            guard let self, pendingText != nil else { return false }
            confirmPending()
            return true
        }
        // Nido embebe LoroKit y captura el mismo atajo cuando está al frente: Loro cede.
        hotkey.yieldWhenFrontmost = ["cl.manulit0.nido"]
        let ok = hotkey.start(hotkey: settings.hotkey)
        log.info("hotkey \(self.settings.hotkey.rawValue, privacy: .public) → tap \(ok ? "activo" : "FALLÓ (¿Accesibilidad?)", privacy: .public)")
    }

    private func applySettings(from old: LoroSettings) {
        if old.hotkey != settings.hotkey { _ = hotkey.start(hotkey: settings.hotkey) }
        if old.engine != settings.engine || old.whisperModel != settings.whisperModel || old.whisperLanguage != settings.whisperLanguage || old.appleLocale != settings.appleLocale {
            if old.whisperModel != settings.whisperModel || old.whisperLanguage != settings.whisperLanguage { session.invalidateEngine(.whisper) }
            if old.appleLocale != settings.appleLocale { session.invalidateEngine(.apple) }
            prepareCurrentEngine()
        }
    }

    // MARK: - Motores

    func prepareCurrentEngine() { session.prepareEngine() }

    static func micModeName(_ m: AVCaptureDevice.MicrophoneMode) -> String { DictationSession.micModeName(m) }

    // MARK: - Push to talk

    private func hotkeyPressed() {
        hotkeyIsDown = true
        hotkeyPressedAt = Date()
        switch settings.hotkeyMode {
        case .pushToTalk: startRecording()
        case .toggle: status == .recording ? finishRecording() : startRecording()
        case .hybrid:
            if status == .recording { finishRecording() }   // segundo toque cierra
            else { recordingStartedByTap = false; startRecording() }
        }
    }

    private func hotkeyReleased() {
        hotkeyIsDown = false
        switch settings.hotkeyMode {
        case .pushToTalk: finishRecording()
        case .toggle: break
        case .hybrid:
            // Toque corto: fue un tap, seguimos grabando hasta el próximo toque.
            // Presión larga: push-to-talk clásico, soltar cierra.
            guard status == .recording, !recordingStartedByTap else { return }
            if Date().timeIntervalSince(hotkeyPressedAt) < LoroSettings.HotkeyMode.tapThreshold { recordingStartedByTap = true }
            else { finishRecording() }
        }
    }

    /// Enter: pega el dictado que estaba esperando.
    func confirmPending() {
        guard let text = pendingText else { return }
        pendingText = nil
        hud.hide()
        let outcome = Paster.insert(text, allowPaste: hasAccessibility)
        log.info("texto confirmado con Enter, entregado vía \(String(describing: outcome), privacy: .public)")
        if settings.playSounds { NSSound(named: "Tink")?.play() }
    }

    /// Esc: no pega. El texto sigue en el portapapeles para un ⌘V manual.
    func discardPending() {
        pendingText = nil
        hud.hide()
    }

    func startRecording() {
        if pendingText != nil { discardPending() }
        guard enginePhase == .ready else {
            log.notice("hotkey presionado pero el motor no está listo")
            hud.flash("El motor todavía no está listo"); return
        }
        // El HUD aparece al tiro: con el micrófono de un audífono Bluetooth pasan unas décimas
        // antes de que se pueda hablar.
        micStarting = true
        hud.show()
        Task {
            let started = await session.start()
            micStarting = false
            guard started else {
                if status == .idle { hud.hide() }
                return
            }
            if settings.playSounds { NSSound(named: "Pop")?.play() }
            // Toque más corto que el arranque del mic: la soltada ya pasó, cerramos ahora.
            // (En híbrido, una soltada rápida es un tap: se sigue grabando.)
            if settings.hotkeyMode == .pushToTalk, !hotkeyIsDown { finishRecording() }
            if settings.hotkeyMode == .hybrid, !hotkeyIsDown { recordingStartedByTap = true }
        }
    }

    func cancelRecording() { session.cancel() }

    func finishRecording() {
        guard session.isRecording else { return }
        Task {
            let r = await session.finish()
            guard let r else { return }
            deliver(r, paste: settings.pasteAfterTranscribe)
        }
    }

    /// Vuelve a leer del disco lo que la UI muestra. Necesario porque el dictado embebido de
    /// Nido escribe en los mismos archivos: sin esto, la ventana muestra solo lo de esta app.
    func reloadHistory() {
        history = HistoryStore.loadHistory()
        stats = HistoryStore.loadStats()
        historyStamp = Self.historyModified()
    }

    /// Ids de dictados que se están re-transcribiendo ahora (para el spinner de la fila).
    private(set) var retranscribing: Set<UUID> = []

    /// Vuelve a transcribir con Whisper un dictado del historial que tenga audio guardado.
    /// Whisper va forzado a español, así que es el rescate cuando el motor rápido se desvió.
    /// Deja el texto nuevo en la fila y en el portapapeles.
    func retranscribeWithWhisper(_ item: StoredDictation) {
        guard let url = item.audioURL, !retranscribing.contains(item.id) else { return }
        retranscribing.insert(item.id)
        Task {
            defer { retranscribing.remove(item.id) }
            guard let clip = try? AudioClip.load(url: url) else {
                hud.flash("No se pudo abrir el audio"); return
            }
            guard let r = await session.retranscribe(clip, with: .whisper) else {
                hud.flash("Whisper no sacó texto de ese audio"); return
            }
            HistoryStore.updateText(id: item.id, text: r.text, engine: .whisper, stages: r.stages)
            reloadHistory()
            Paster.copyOnly(r.text)
            lastTranscript = r.text
            hud.flash("Re-transcrito con Whisper y copiado")
        }
    }

    /// Última fecha de modificación vista de history.json, para no releer 88 KB cada vuelta.
    private var historyStamp: Date?

    private static func historyModified() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: HistoryStore.historyURL.path)[.modificationDate]) as? Date
    }

    /// Si Nido dictó, el archivo cambió bajo nuestros pies: recargamos. El menú usa
    /// `.menuBarExtraStyle(.window)` y su `onAppear` no vuelve a dispararse, así que este
    /// chequeo es lo que mantiene la lista al día.
    func reloadHistoryIfChanged() {
        let stamp = Self.historyModified()
        guard stamp != historyStamp else { return }
        reloadHistory()
    }

    /// Lo que Loro hace con un resultado: historial, estadísticas y pegado.
    private func deliver(_ r: DictationResult, paste: Bool) {
        let text = r.text
        // Un dictado mudo no se pega, pero `record` igual guarda el WAV para poder auditarlo.
        HistoryStore.record(r, settings: settings)
        reloadHistory()
        guard !text.isEmpty else { return }
        lastTranscript = text
        if paste, settings.confirmWithEnter, r.source == "Dictado" {
            Paster.copyOnly(text)
            pendingText = text
            hud.show()
            if settings.playSounds { NSSound(named: "Pop")?.play() }
        } else if paste {
            let outcome = Paster.insert(text, allowPaste: hasAccessibility)
            log.info("texto entregado vía \(String(describing: outcome), privacy: .public)")
            if settings.playSounds { NSSound(named: "Tink")?.play() }
        }
    }

    // MARK: - Modo de micrófono del sistema

    var micModeSessionActive = false

    /// El selector de "Modo de micrófono" de macOS solo aparece si la app tiene el micrófono
    /// abierto en ese momento. Abrimos el mic sin transcribir, mostramos el panel, y cerramos
    /// cuando el usuario termina (o a los 30 s).
    func beginMicModeSelection() {
        guard status == .idle else { return }
        Task {
            do {
                try await session.beginMicModeSelection()
                micModeSessionActive = true
                try? await Task.sleep(for: .seconds(30))
                endMicModeSelection()
            } catch {
                hud.flash(error.localizedDescription)
            }
        }
    }

    func endMicModeSelection() {
        guard micModeSessionActive else { return }
        micModeSessionActive = false
        session.endMicModeSelection()
    }

    // MARK: - Archivos

    struct FileJob: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        var state: State = .queued
        enum State: Equatable { case queued, running, done(String), failed(String) }
    }

    var fileJobs: [FileJob] = []

    func transcribeFiles(_ urls: [URL]) {
        for url in urls where !fileJobs.contains(where: { $0.url == url }) {
            fileJobs.append(FileJob(url: url))
        }
        Task { await drainFileJobs() }
    }

    private var draining = false
    private func drainFileJobs() async {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while let idx = fileJobs.firstIndex(where: { $0.state == .queued }) {
            let url = fileJobs[idx].url
            fileJobs[idx].state = .running
            do {
                let clip = try AudioClip.load(url: url)
                let result = await session.transcribe(clip, source: url.lastPathComponent)
                if let r = result { deliver(r, paste: false) }
                if let i = fileJobs.firstIndex(where: { $0.url == url }) {
                    fileJobs[i].state = result.map { .done($0.text) } ?? .failed(status.label)
                }
            } catch {
                if let i = fileJobs.firstIndex(where: { $0.url == url }) { fileJobs[i].state = .failed(error.localizedDescription) }
            }
        }
    }

    func clearFinishedJobs() {
        fileJobs.removeAll { if case .queued = $0.state { return false }; if case .running = $0.state { return false }; return true }
    }
}
