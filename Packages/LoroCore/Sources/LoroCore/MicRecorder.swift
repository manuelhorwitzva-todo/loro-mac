@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os
import LoroObjC

let micLog = Logger(subsystem: "cl.manulit0.loro", category: "mic")

/// Graba del micrófono por defecto y acumula samples en el formato canónico.
/// Es un actor: el tap de AVAudioEngine llama desde un hilo de audio en tiempo real,
/// y el actor serializa el acceso al buffer sin locks a mano.
public actor MicRecorder {
    private var engine = AVAudioEngine()
    private var samples: [Float] = []
    private var running = false
    /// Hay una grabación en curso desde el punto de vista de quien llama (entre start y stop),
    /// aunque el motor esté cerrado un instante mientras se reabre.
    private var wanted = false
    private var levelHandler: (@Sendable (Float) -> Void)?
    private var voiceIsolation = true
    /// Captura directa del micrófono de un audífono Bluetooth (ver `openBluetooth`).
    private var hal: (device: AudioDeviceID, proc: AudioDeviceIOProcID)?
    private let halQueue = DispatchQueue(label: "cl.manulit0.loro.mic.bluetooth")
    /// Entrada del sistema que había antes de pasarnos al micrófono del Mac, para reponerla.
    private var previousInput: AudioDeviceID?
    private var configObserver: NSObjectProtocol?
    private var watchdog: Task<Void, Never>?
    /// Reaperturas del motor en esta grabación, para no quedar en un loop si el audio no se asienta.
    private var restarts = 0
    static let maxRestarts = 8
    public private(set) var voiceProcessingError: String?
    public var isVoiceProcessingActive: Bool { engine.inputNode.isVoiceProcessingEnabled }

    public init() {}

    public var isRecording: Bool { running }

    /// Pide permiso de micrófono si todavía no se ha concedido. Devuelve true si se puede grabar.
    public static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// `voiceIsolation` activa el procesador de voz de Apple (el de FaceTime): suprime ruido
    /// de fondo y voces lejanas antes de que el audio llegue al motor.
    /// Intentos para abrir el micrófono y espera entre cada uno: ~1 s en total, lo que tarda un
    /// audífono Bluetooth en reconfigurarse.
    static let startAttempts = 6
    static let retryDelay: Duration = .milliseconds(200)

    /// `preferBuiltInMic`: con audífonos Bluetooth, graba con el micrófono del Mac. Abrir el
    /// del audífono lo saca de A2DP y lo deja en manos libres (HFP, 16 kHz mono): la música
    /// suena a llamada telefónica y el cambio de modo corta el motor (12-oct, soundcore
    /// Liberty 5 y WH-1000XM6).
    public func start(voiceIsolation: Bool = true, preferBuiltInMic: Bool = true,
                      onLevel: (@Sendable (Float) -> Void)? = nil) async throws {
        guard !running, !wanted else { return }
        samples.removeAll(keepingCapacity: true)
        levelHandler = onLevel
        self.voiceIsolation = voiceIsolation
        restarts = 0
        wanted = true
        if preferBuiltInMic, previousInput == nil {
            previousInput = InputDevices.switchToBuiltInMicIfBluetooth()
            if previousInput != nil {
                micLog.info("audífono Bluetooth: se graba con el micrófono del Mac")
                // El cambio tarda en asentarse: abrir el motor al tiro todavía toca el audífono
                // (microcorte a manos libres) y el primer intento falla con -10868.
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        let bluetooth = InputDevices.bluetoothDefaultInput()
        if !voiceIsolation, let bluetooth, openBluetooth(bluetooth) {
            micLog.info("audífono Bluetooth: captura directa")
        } else {
            do { try await openEngine() } catch { wanted = false; restoreInput(); throw error }
            armWatchdog()
        }
        // Con el micrófono de un audífono Bluetooth el audio tarda en llegar, mientras el
        // audífono pasa a manos libres. Se espera aquí para que quien llama avise "grabando"
        // recién cuando de verdad se escucha y no se pierdan las primeras palabras.
        if bluetooth != nil {
            for _ in 0..<50 where wanted && samples.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
        }
    }

    /// Graba del audífono Bluetooth con un IOProc de CoreAudio, sin AVAudioEngine. Al abrir su
    /// micrófono el audífono pasa a manos libres y cambia de formato; AVAudioEngine se detiene
    /// con ese cambio y reabrirlo saca al audífono de manos libres y lo vuelve a meter: 1,2 a
    /// 1,7 s sin grabar (12-oct, WH-1000XM6). El IOProc sigue corriendo durante el cambio y
    /// entrega audio a los ~0,3 s. false si no se pudo, para caer al motor de siempre.
    private func openBluetooth(_ device: AudioDeviceID) -> Bool {
        guard var description = InputDevices.inputFormat(of: device),
              let format = AVAudioFormat(streamDescription: &description) else { return false }
        var proc: AudioDeviceIOProcID?
        let created = AudioDeviceCreateIOProcIDWithBlock(&proc, device, halQueue) { [weak self] _, input, _, _, _ in
            guard let self, let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input),
                  let clip = try? AudioClip.resample(buffer) else { return }
            let samples = clip.samples
            let level = clip.rms
            Task { await self.append(samples, level: level) }
        }
        guard created == noErr, let proc else { return false }
        // Bloquea mientras el audífono pasa a manos libres (0,3 a 0,7 s).
        guard AudioDeviceStart(device, proc) == noErr else {
            AudioDeviceDestroyIOProcID(device, proc)
            return false
        }
        hal = (device, proc)
        running = true
        return true
    }

    /// Abre un motor nuevo sobre el micrófono por defecto, con reintentos.
    ///
    /// Nido se cerró 3 veces el 14-sep dentro de installTap, dictando con AirPods y música
    /// sonando: AVFoundation lanza una excepción ObjC si el formato del bus no es válido al
    /// instalar el tap, y Swift no la puede atrapar. Tres defensas:
    /// - un motor nuevo en cada intento: uno detenido guarda el dispositivo de la vez anterior;
    /// - el formato se valida entero (sample rate Y canales) antes del tap;
    /// - la excepción se atrapa con LoroObjC y se reintenta mientras el audio se asienta.
    private func openEngine() async throws {
        var problem = "no hay micrófono disponible"
        for attempt in 0..<Self.startAttempts {
            if attempt > 0 {
                micLog.notice("micrófono no listo (intento \(attempt, privacy: .public)): \(problem, privacy: .public)")
                try await Task.sleep(for: Self.retryDelay)
                guard wanted, !running else { return }
            }
            let engine = AVAudioEngine()
            self.engine = engine
            let input = engine.inputNode
            if input.isVoiceProcessingEnabled != voiceIsolation {
                do { try input.setVoiceProcessingEnabled(voiceIsolation) }
                catch { voiceProcessingError = error.localizedDescription }
            }
            if voiceIsolation {
                // Sin ducking del audio del sistema: no somos una llamada.
                input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            }
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                problem = "formato inválido (\(Int(format.sampleRate)) Hz, \(format.channelCount) canales)"
                continue
            }
            // format: nil a propósito. Pasarle el formato que acabamos de leer crashea la app si
            // el nodo se reconfigura entremedio — cambiar de micrófono, conectar AirPods, o el
            // propio toggle de voiceProcessing de acá arriba. Con nil, AVFoundation resuelve el
            // formato del bus al instalar el tap. El bloque resamplea igual, así que no dependemos
            // del sample rate que venga.
            let exception = LoroCatchException {
                input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
                    guard let self else { return }
                    // Convertimos AQUÍ, en el hilo de audio, a [Float] (que es Sendable) antes de
                    // cruzar al actor: el buffer original lo recicla CoreAudio y no se puede mandar.
                    guard let clip = try? AudioClip.resample(buffer) else { return }
                    let samples = clip.samples
                    let level = clip.rms
                    Task { await self.append(samples, level: level) }
                }
            }
            if let exception { problem = exception; continue }
            // El observer va ANTES de start(): con audífonos Bluetooth, abrir el micrófono pasa el
            // audífono de A2DP a manos libres (HFP, 16 kHz) y AVAudioEngine se detiene solo a los
            // pocos ms de arrancar ("iounit configuration changed > stopping the engine"). Sin
            // esto la grabación seguía "abierta" pero sin recibir audio: 0.00 s, había que apretar
            // el atajo dos veces (25-sep, audífonos Resolute).
            observeConfigurationChanges(of: engine)
            var startError: Error?
            if let exception = LoroCatchException({
                engine.prepare()
                do { try engine.start() } catch { startError = error }
            }) { problem = exception; input.removeTap(onBus: 0); continue }
            if let startError { problem = startError.localizedDescription; input.removeTap(onBus: 0); continue }
            running = true
            return
        }
        stopObservingConfigurationChanges()
        micLog.error("no se pudo abrir el micrófono: \(problem, privacy: .public)")
        throw LoroError.audio("El micrófono no respondió (\(problem)). Si tienes audífonos Bluetooth, prueba de nuevo en un segundo.")
    }

    private func observeConfigurationChanges(of engine: AVAudioEngine) {
        stopObservingConfigurationChanges()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.restartEngine(reason: "cambió la configuración del audio") }
        }
    }

    private func stopObservingConfigurationChanges() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
    }

    /// Reabre el motor sin perder lo ya grabado. Lo llaman el cambio de configuración y el
    /// watchdog; si la grabación ya terminó no hace nada.
    private func restartEngine(reason: String) async {
        guard wanted, running, hal == nil else { return }
        guard restarts < Self.maxRestarts else {
            micLog.error("micrófono: demasiadas reaperturas, se deja como está (\(reason, privacy: .public))")
            return
        }
        restarts += 1
        micLog.notice("reabriendo el micrófono (\(self.restarts, privacy: .public)): \(reason, privacy: .public)")
        stopObservingConfigurationChanges()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        do {
            try await openEngine()
            armWatchdog()
        } catch {
            micLog.error("no se pudo reabrir el micrófono: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Red de seguridad por si el motor queda mudo sin avisar: si al rato de abrir no llegó ni
    /// un buffer, se reabre. Con 600 ms se reabría justo cuando el audífono Bluetooth terminaba
    /// de pasar a manos libres (tarda ~0,7 s) y volvía a empezar: 4,7 s sin grabar con los
    /// WH-1000XM6 el 12-oct.
    static let watchdogDelay: Duration = .milliseconds(1500)

    private func armWatchdog() {
        watchdog?.cancel()
        let before = samples.count
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.watchdogDelay)
            guard !Task.isCancelled, let self else { return }
            await self.checkWatchdog(samplesBefore: before)
        }
    }

    private func checkWatchdog(samplesBefore: Int) async {
        guard running, samples.count == samplesBefore else { return }
        await restartEngine(reason: "sin audio")
    }

    private func append(_ chunk: [Float], level: Float) {
        guard running else { return }
        samples.append(contentsOf: chunk)
        levelHandler?(level)
    }

    private func restoreInput() {
        if let previousInput { InputDevices.restoreDefaultInput(previousInput) }
        previousInput = nil
    }

    /// Copia de lo grabado hasta ahora, sin detener. Sirve para el preview en vivo.
    public func snapshot(lastSeconds: Double? = nil) -> AudioClip {
        guard let lastSeconds else { return AudioClip(samples: samples) }
        let n = Int(lastSeconds * AudioClip.sampleRate)
        return AudioClip(samples: samples.count > n ? Array(samples.suffix(n)) : samples)
    }

    /// Detiene la grabación y devuelve todo lo capturado.
    public func stop() -> AudioClip {
        wanted = false
        watchdog?.cancel()
        watchdog = nil
        stopObservingConfigurationChanges()
        defer { restoreInput() }
        guard running else { return AudioClip(samples: samples) }
        if let hal {
            AudioDeviceStop(hal.device, hal.proc)
            AudioDeviceDestroyIOProcID(hal.device, hal.proc)
            self.hal = nil
        } else {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            // Motor nuevo, sin nodo de entrada: uno detenido sigue enganchado al micrófono y, si
            // es el de un audífono Bluetooth, lo deja pegado en manos libres con la música a 16 kHz.
            engine = AVAudioEngine()
        }
        running = false
        levelHandler = nil
        return AudioClip(samples: samples)
    }
}
