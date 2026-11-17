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
    /// Grabar reunión (micrófono + audio del navegador).
    let meeting: MeetingController
    /// Si la tecla ya se soltó mientras el micrófono todavía arrancaba, cerramos al tiro.
    private var hotkeyIsDown = false
    private var hotkeyPressedAt = Date.distantPast
    private var hotkeyReleasedAt = Date.distantPast
    /// Modo híbrido: la grabación la abrió un toque corto, así que la cierra el próximo toque.
    private var recordingStartedByTap = false
    /// Entre que se aprieta el atajo y el micrófono empieza a entregar audio.
    var micStarting = false
    let hud = HUDController()

    private init() {
        let initial = LoroSettings.load()
        settings = initial
        let dictation = DictationSession(settings: { initial }, corrector: { DictionaryCorrector(entries: []) })
        session = dictation
        meeting = MeetingController(session: dictation)
        session.settings = { [unowned self] in self.settings }
        session.corrector = { [unowned self] in self.corrector }
        session.onStatus = { [weak self] st in
            guard let self else { return }
            status = st
            switch st {
            case .error(let e): flash(e)
            case .preparing(let m): if hudVisible { flash(m) }
            default: break   // grabando, transcribiendo y reposo: el HUD se deriva solo (`hudVisible`)
            }
        }
        session.onEnginePhase = { [weak self] p in self?.enginePhase = p }
        session.onLevel = { [weak self] l in self?.level = l }
        session.onLive = { [weak self] c, v in
            guard let self else { return }
            liveCommitted = c; liveVolatile = v
            liveText = v.isEmpty ? c : (c.isEmpty ? v : c + " " + v)
        }
        hud.attach(to: self)
    }

    // MARK: - HUD

    /// Aviso pasajero del HUD ("Reunión guardada", un error…). Se borra solo.
    private(set) var hudMessage: String?
    private var hudMessageTask: Task<Void, Never>?

    /// Muestra un aviso unos segundos. No esconde nada: si hay un dictado grabándose o esperando
    /// Enter, la cajita sigue ahí cuando el aviso se va.
    func flash(_ message: String, for duration: Duration = .seconds(2.5)) {
        hudMessageTask?.cancel()
        hudMessage = message
        hudMessageTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.hudMessage = nil
        }
    }

    /// La cajita se ve si y solo si hay algo que mostrar. Es la única regla.
    var hudVisible: Bool {
        HUDRule.visible(micStarting: micStarting, status: status, pending: pendingText != nil, message: hudMessage != nil)
    }

    /// Por qué está (o no) visible, para el log.
    var hudReason: String {
        var r: [String] = []
        if micStarting { r.append("abriendo micrófono") }
        if status == .recording { r.append("grabando") }
        if status == .transcribing { r.append("transcribiendo") }
        if pendingText != nil { r.append("esperando Enter") }
        if let m = hudMessage { r.append("aviso: \(m)") }
        return r.isEmpty ? "nada que mostrar" : r.joined(separator: ", ")
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
        case .pushToTalk: startRecording(fromHotkey: true)
        case .toggle: status == .recording ? finishRecording() : startRecording(fromHotkey: true)
        case .hybrid:
            if status == .recording { finishRecording() }   // segundo toque cierra
            else { recordingStartedByTap = false; startRecording(fromHotkey: true) }
        }
    }

    private func hotkeyReleased() {
        hotkeyIsDown = false
        hotkeyReleasedAt = Date()
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
        let outcome = Paster.insert(text, allowPaste: hasAccessibility)
        log.info("texto confirmado con Enter, entregado vía \(String(describing: outcome), privacy: .public)")
        if settings.playSounds { NSSound(named: "Tink")?.play() }
    }

    /// Esc: no pega. El texto sigue en el portapapeles para un ⌘V manual.
    func discardPending() {
        pendingText = nil
    }

    /// `fromHotkey`: false cuando parte del botón del menú, donde no hay tecla que soltar.
    func startRecording(fromHotkey: Bool = false) {
        // Otro toque mientras el micrófono todavía abre, o mientras se transcribe: no hay nada
        // que empezar. Antes ese segundo intento fallaba y de paso escondía la cajita del primero.
        guard !micStarting, status != .recording, status != .transcribing else {
            log.notice("hotkey ignorado: ya hay un dictado en curso (\(self.hudReason, privacy: .public))")
            return
        }
        if pendingText != nil { discardPending() }
        guard enginePhase == .ready else {
            log.notice("hotkey presionado pero el motor no está listo")
            flash("El motor todavía no está listo"); return
        }
        // El HUD aparece al tiro (`micStarting` lo prende): con el micrófono de un audífono
        // Bluetooth pasan unas décimas antes de que se pueda hablar.
        micStarting = true
        Task {
            let started = await session.start()
            micStarting = false
            guard started else {
                log.notice("el micrófono no partió (estado: \(self.status.label, privacy: .public))")
                // El mismo error dos veces seguidas no vuelve a avisar por `onStatus` (el estado
                // no cambia), así que se avisa acá: si no, la cajita se iría sin decir nada.
                if case .error(let e) = status { flash(e) }
                return
            }
            if settings.playSounds { NSSound(named: "Pop")?.play() }
            // Toque más corto que el arranque del mic: la soltada ya pasó, cerramos ahora.
            if settings.hotkeyMode == .pushToTalk, !hotkeyIsDown { finishRecording() }
            // En híbrido depende de cuánto estuvo apretada: un toque corto sigue grabando; una
            // presión larga que ya se soltó se cierra (si no, quedaba pegado en "Escuchando…").
            if settings.hotkeyMode == .hybrid, !hotkeyIsDown {
                // Desde el botón del menú no hay tecla: queda grabando hasta el próximo toque.
                guard fromHotkey else { recordingStartedByTap = true; return }
                let held = hotkeyReleasedAt.timeIntervalSince(hotkeyPressedAt)
                if HUDRule.keepsRecordingAfterEarlyRelease(heldFor: held) { recordingStartedByTap = true }
                else {
                    log.notice("tecla soltada tras \(held, format: .fixed(precision: 2))s, antes de que abriera el micrófono: se cierra")
                    finishRecording()
                }
            }
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
                flash("No se pudo abrir el audio"); return
            }
            guard let r = await session.retranscribe(clip, with: .whisper) else {
                flash("Whisper no sacó texto de ese audio"); return
            }
            HistoryStore.updateText(id: item.id, text: r.text, engine: .whisper, stages: r.stages)
            reloadHistory()
            Paster.copyOnly(r.text)
            lastTranscript = r.text
            flash("Re-transcrito con Whisper y copiado")
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
            if settings.playSounds { NSSound(named: "Pop")?.play() }
        } else if paste {
            let outcome = Paster.insert(text, allowPaste: hasAccessibility)
            log.info("texto entregado vía \(String(describing: outcome), privacy: .public)")
            if settings.playSounds { NSSound(named: "Tink")?.play() }
        }
    }

    // MARK: - Modo de prueba (HUDDemo): mueve solo lo que el HUD dibuja

    func demoRecording(_ on: Bool) {
        status = on ? .recording : .idle
        level = on ? 0.06 : 0
        if !on { demoLive(committed: "", volatile: "") }
    }
    func demoLive(committed c: String, volatile v: String) {
        liveCommitted = c; liveVolatile = v
        liveText = v.isEmpty ? c : (c.isEmpty ? v : c + " " + v)
    }
    func demoPending(_ text: String?) {
        pendingText = text
    }
    func demoFlash(_ m: String) { flash(m) }
    func demoMicStarting(_ on: Bool) { micStarting = on }

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
                flash(error.localizedDescription)
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
