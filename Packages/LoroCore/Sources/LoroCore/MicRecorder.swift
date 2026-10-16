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
    /// Captura directa de un dispositivo con un IOProc de CoreAudio, sin AVAudioEngine (ver `openDevice`).
    private var hal: (device: AudioDeviceID, proc: AudioDeviceIOProcID)?
    private let halQueue = DispatchQueue(label: "cl.manulit0.loro.mic.bluetooth")
    /// Entrada del sistema que había antes de pasarnos al micrófono del Mac, para reponerla.
    private var previousInput: AudioDeviceID?
    private var configObserver: NSObjectProtocol?
    private var watchdog: Task<Void, Never>?
    /// Reaperturas del motor en esta grabación, para no quedar en un loop si el audio no se asienta.
    private var restarts = 0
    static let maxRestarts = 8
    /// Motores reemplazados al reabrir, que todavía no se pueden soltar. Nido se cerró 2 veces el
    /// 16-oct con audífonos: el watchdog reabría el motor y soltar el viejo justo ahí, con el audio
    /// cambiando de dispositivo, revienta en `-[AVAudioEngine dealloc]` (DeallocateInputBlock lanza
    /// una excepción dentro de un destructor C++ y no hay cómo atraparla). Se sueltan unos segundos
    /// después de `stop()`, con el audio ya asentado.
    private var retiredEngines: [AVAudioEngine] = []
    private var releaseTask: Task<Void, Never>?
    static let releaseDelay: Duration = .seconds(3)
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

    /// `preferBuiltInMic`: con audífonos Bluetooth, graba con el micrófono del Mac en vez del
    /// audífono. Abrir el del audífono lo deja en manos libres (24 kHz con AirPods Pro): la música
    /// suena a llamada telefónica mientras se dicta. Por default se usa el micrófono que esté
    /// conectado y la música se pausa (`MediaPause`, 16-oct).
    public func start(voiceIsolation: Bool = true, preferBuiltInMic: Bool = false,
                      onLevel: (@Sendable (Float) -> Void)? = nil) async throws {
        guard !running, !wanted else { return }
        samples.removeAll(keepingCapacity: true)
        levelHandler = onLevel
        self.voiceIsolation = voiceIsolation
        restarts = 0
        wanted = true
        // Con audífonos Bluetooth, el micrófono del Mac se abre directo, sin cambiar la entrada del
        // sistema ni pasar por AVAudioEngine. Cambiar la entrada y reponerla al terminar alcanzaba a
        // abrir el micrófono del audífono un instante, y eso lo pasa a manos libres: la música
        // sonaba como llamada al dictar o al volver (16-oct, AirPods Pro). Así el audífono no se toca.
        if preferBuiltInMic, !voiceIsolation, let builtIn = InputDevices.builtInMicIfBluetoothDefault(),
           openDevice(builtIn) {
            micLog.info("audífono Bluetooth: se graba directo con el micrófono del Mac")
            return
        }
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
        if !voiceIsolation, let bluetooth, openDevice(bluetooth) {
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

    /// Graba de un dispositivo con un IOProc de CoreAudio, sin AVAudioEngine: el micrófono del
    /// audífono Bluetooth, o el del Mac cuando se pide. Al abrir su micrófono el audífono pasa a
    /// manos libres y cambia de formato; AVAudioEngine se detiene con ese cambio y reabrirlo saca
    /// al audífono de manos libres y lo vuelve a meter: 1,2 a 1,7 s sin grabar (12-oct, WH-1000XM6).
    /// El IOProc sigue corriendo durante el cambio y entrega audio a los ~0,1 s. false si no se
    /// pudo, para caer al motor de siempre.
    private func openDevice(_ device: AudioDeviceID) -> Bool {
        let converter = StreamConverter(device: device)
        var proc: AudioDeviceIOProcID?
        let created = AudioDeviceCreateIOProcIDWithBlock(&proc, device, halQueue) { [weak self] _, input, _, _, _ in
            guard let self, let clip = converter.convert(input) else { return }
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
            retiredEngines.append(self.engine)
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
            // Si hubo reaperturas, el motor actual puede venir del mismo enredo: se suelta después.
            if restarts > 0 { retiredEngines.append(engine) }
            engine = AVAudioEngine()
        }
        running = false
        levelHandler = nil
        scheduleRelease()
        return AudioClip(samples: samples)
    }

    private func scheduleRelease() {
        guard !retiredEngines.isEmpty else { return }
        releaseTask?.cancel()
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: Self.releaseDelay)
            guard !Task.isCancelled, let self else { return }
            await self.releaseRetiredEngines()
        }
    }

    /// Si ya empezó otra grabación, espera al próximo `stop()`.
    private func releaseRetiredEngines() {
        guard !wanted else { return }
        retiredEngines.removeAll()
    }
}

/// Convierte lo que entrega el IOProc al formato canónico, siguiendo los cambios de formato del
/// dispositivo. Un audífono Bluetooth cambia de 48 a 24 kHz apenas se abre su micrófono, ya con el
/// IOProc corriendo: con el formato leído al abrir, el audio de 24 kHz se leía como de 48 y la
/// grabación quedaba a la mitad de duración y acelerada (16-oct, AirPods Pro: 5 s → 2,5 s).
/// Se usa siempre desde la misma cola del IOProc, así que no necesita locks.
private final class StreamConverter: @unchecked Sendable {
    private let device: AudioDeviceID
    private var description = AudioStreamBasicDescription()
    private var format: AVAudioFormat?
    /// Uno por formato y no uno por buffer: los buffers son de ~10 ms y un conversor nuevo
    /// reinicia el filtro en cada borde.
    private var converter: AVAudioConverter?

    init(device: AudioDeviceID) { self.device = device }

    func convert(_ input: UnsafePointer<AudioBufferList>) -> AudioClip? {
        guard var current = InputDevices.inputFormat(of: device) else { return nil }
        if format == nil || !Self.same(current, description) {
            guard let f = AVAudioFormat(streamDescription: &current),
                  let c = AVAudioConverter(from: f, to: AudioClip.canonicalFormat) else { return nil }
            if format != nil {
                micLog.notice("el micrófono cambió de formato: \(Int(self.description.mSampleRate), privacy: .public) → \(Int(current.mSampleRate), privacy: .public) Hz")
            }
            description = current; format = f; converter = c
        }
        guard let format, let converter,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input), buffer.frameLength > 0,
              let out = AVAudioPCMBuffer(pcmFormat: AudioClip.canonicalFormat,
                                         frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * AudioClip.sampleRate / format.sampleRate) + 64)
        else { return nil }
        var fed = false
        _ = converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard out.frameLength > 0, let data = out.floatChannelData else { return nil }
        return AudioClip(samples: Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength))))
    }

    private static func same(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
        a.mSampleRate == b.mSampleRate && a.mChannelsPerFrame == b.mChannelsPerFrame
            && a.mBytesPerFrame == b.mBytesPerFrame && a.mFormatFlags == b.mFormatFlags && a.mFormatID == b.mFormatID
    }
}
