@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os

let meetingLog = Logger(subsystem: "cl.manulit0.loro", category: "meeting")

/// Graba una reunión en dos pistas separadas: el micrófono (quien graba) y el audio que sale
/// del navegador (los demás). Separadas porque así se sabe quién habló sin adivinar, y porque
/// la voz de los demás llega limpia, sin pasar por el parlante y el micrófono.
///
/// Escribe a disco MIENTRAS graba (CAF PCM, que se puede leer aunque la app se caiga a mitad),
/// y al terminar exporta a m4a: `tu.m4a`, `otros.m4a` y `reunion.m4a` (las dos mezcladas).
public final class MeetingRecorder: @unchecked Sendable {
    public struct Levels: Sendable { public var mic: Float; public var system: Float }

    public struct Result: Sendable {
        public var folder: URL
        public var micURL: URL
        public var systemURL: URL
        public var mixURL: URL
        public var started: Date
        public var duration: TimeInterval
        /// Segundos con señal en cada pista: 0 en "otros" con la reunión sonando = falta permiso.
        public var micSignalSeconds: Double
        public var systemSignalSeconds: Double
    }

    public static let sampleRate: Double = 48_000
    static var trackFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    }

    public let folder: URL
    public private(set) var started = Date()
    private var startHost: UInt64 = 0
    private let mic: TrackWriter
    private let system: TrackWriter
    private let systemCapture = SystemAudioCapture()
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private let lock = NSLock()
    private var running = false

    public init(folder: URL) throws {
        self.folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        mic = try TrackWriter(url: folder.appendingPathComponent("tu.caf"), name: "mic")
        system = try TrackWriter(url: folder.appendingPathComponent("otros.caf"), name: "system")
    }

    public var isRunning: Bool { lock.withLock { running } }

    public var levels: Levels { Levels(mic: mic.level, system: system.level) }
    public var signalSeconds: (mic: Double, system: Double) { (mic.signalSeconds, system.signalSeconds) }

    /// `bundleIDs` vacío graba todo el audio del Mac (salvo Loro).
    public func start(bundleIDs: [String] = SystemAudioCapture.meetingBundleIDs) throws {
        started = Date()
        startHost = mach_absolute_time()
        mic.startHost = startHost
        system.startHost = startHost
        try systemCapture.start(bundleIDs: bundleIDs) { [system] buffer, time in
            system.append(buffer, hostTime: time?.hostTime)
        }
        do { try startMic() } catch { systemCapture.stop(); throw error }
        lock.withLock { running = true }
        meetingLog.info("reunión grabando en \(self.folder.lastPathComponent, privacy: .public)")
    }

    private func startMic() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw LoroError.audio("No hay micrófono disponible") }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [mic] buffer, time in
            mic.append(buffer, hostTime: time.isHostTimeValid ? time.hostTime : nil)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        // Cambio de micrófono a mitad (se conectan los AirPods, Meet cambia la entrada):
        // el motor se detiene solo. Se reabre con el dispositivo nuevo y la pista sigue.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                                queue: nil) { [weak self] _ in
            guard let self, self.isRunning else { return }
            meetingLog.notice("cambió el micrófono: reabriendo")
            self.restartMic()
        }
        meetingLog.info("micrófono: \(format.sampleRate, format: .fixed(precision: 0)) Hz, \(format.channelCount) canales")
    }

    private func restartMic() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        // El dispositivo nuevo tarda unas décimas en quedar listo (Bluetooth).
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.isRunning else { return }
            do { try self.startMic() } catch { meetingLog.error("no se pudo reabrir el micrófono: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// Detiene la captura y exporta los m4a. Tarda unos segundos por hora de reunión.
    public func stop() async throws -> Result {
        lock.withLock { running = false }
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        systemCapture.stop()
        let duration = Date().timeIntervalSince(started)
        await mic.close()
        await system.close()
        let result = Result(folder: folder,
                            micURL: folder.appendingPathComponent("tu.m4a"),
                            systemURL: folder.appendingPathComponent("otros.m4a"),
                            mixURL: folder.appendingPathComponent("reunion.m4a"),
                            started: started, duration: duration,
                            micSignalSeconds: mic.signalSeconds, systemSignalSeconds: system.signalSeconds)
        try Self.export(mic: mic.url, system: system.url, to: result)
        meetingLog.info("reunión guardada: \(duration, format: .fixed(precision: 0)) s, señal mic \(result.micSignalSeconds, format: .fixed(precision: 0)) s, otros \(result.systemSignalSeconds, format: .fixed(precision: 0)) s")
        return result
    }

    /// Reunión que quedó a medias (Loro se cerró grabando): los CAF se escriben mientras
    /// graba, así que lo grabado hasta ese momento se puede exportar igual.
    public static func recover(folder: URL) throws -> Result {
        let micCAF = folder.appendingPathComponent("tu.caf"), sysCAF = folder.appendingPathComponent("otros.caf")
        let fm = FileManager.default
        // Una pista que nunca recibió audio puede no tener nada legible: se reemplaza por una vacía.
        for url in [micCAF, sysCAF] where (try? AVAudioFile(forReading: url)) == nil {
            try? fm.removeItem(at: url)
            _ = try TrackWriter(url: url, name: "vacía")
        }
        let micLen = (try? AVAudioFile(forReading: micCAF).length) ?? 0
        let sysLen = (try? AVAudioFile(forReading: sysCAF).length) ?? 0
        let attrs = try? fm.attributesOfItem(atPath: folder.path)
        let started = (attrs?[.creationDate] as? Date) ?? Date()
        func signal(_ url: URL) -> Double {
            Double(((try? MeetingTranscriber.frameRMS(of: url)) ?? []).filter { $0 > 0.003 }.count) * MeetingTranscriber.frameSeconds
        }
        let r = Result(folder: folder, micURL: folder.appendingPathComponent("tu.m4a"),
                       systemURL: folder.appendingPathComponent("otros.m4a"), mixURL: folder.appendingPathComponent("reunion.m4a"),
                       started: started, duration: Double(max(micLen, sysLen)) / sampleRate,
                       micSignalSeconds: signal(micCAF), systemSignalSeconds: signal(sysCAF))
        try export(mic: micCAF, system: sysCAF, to: r)
        return r
    }

    /// CAF → m4a (AAC). Por bloques: una hora de reunión no se carga entera en memoria.
    /// Los CAF quedan: son la entrada de la transcripción local y se borran después.
    static func export(mic: URL, system: URL, to r: Result) throws {
        let fmt = trackFormat
        let micIn = try AVAudioFile(forReading: mic)
        let sysIn = try AVAudioFile(forReading: system)
        func aac(_ url: URL, bitRate: Int) throws -> AVAudioFile {
            try? FileManager.default.removeItem(at: url)
            return try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: bitRate,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
        }
        let micOut = try aac(r.micURL, bitRate: 64_000)
        let sysOut = try aac(r.systemURL, bitRate: 64_000)
        let mixOut = try aac(r.mixURL, bitRate: 96_000)
        let chunk: AVAudioFrameCount = 48_000 * 10
        let a = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk)!
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk)!
        let mix = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk)!
        while true {
            a.frameLength = 0; b.frameLength = 0
            if micIn.framePosition < micIn.length { try micIn.read(into: a, frameCount: chunk) }
            if sysIn.framePosition < sysIn.length { try sysIn.read(into: b, frameCount: chunk) }
            let n = max(a.frameLength, b.frameLength)
            if n == 0 { break }
            if a.frameLength > 0 { try micOut.write(from: a) }
            if b.frameLength > 0 { try sysOut.write(from: b) }
            mix.frameLength = n
            let pa = a.floatChannelData![0], pb = b.floatChannelData![0], pm = mix.floatChannelData![0]
            for i in 0..<Int(n) {
                let va = i < Int(a.frameLength) ? pa[i] : 0
                let vb = i < Int(b.frameLength) ? pb[i] : 0
                pm[i] = max(-1, min(1, va + vb))
            }
            try mixOut.write(from: mix)
        }
    }
}

/// Una pista: convierte lo que llegue (48 kHz estéreo del tap, 24 kHz de unos AirPods, lo que
/// sea) a 48 kHz mono y lo escribe a un CAF en una cola aparte, fuera del hilo de audio.
/// Rellena con silencio cuando la pista empieza tarde o tiene un hueco (el micrófono se
/// reabrió), para que las dos pistas queden alineadas en el tiempo.
final class TrackWriter: @unchecked Sendable {
    let url: URL
    let name: String
    var startHost: UInt64 = 0
    private var file: AVAudioFile?
    private let queue: DispatchQueue
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private var framesWritten: Int64 = 0
    private let stateLock = NSLock()
    private var _level: Float = 0
    private var _signalSeconds: Double = 0

    var level: Float { stateLock.withLock { _level } }
    var signalSeconds: Double { stateLock.withLock { _signalSeconds } }

    init(url: URL, name: String) throws {
        self.url = url
        self.name = name
        queue = DispatchQueue(label: "cl.manulit0.loro.track.\(name)", qos: .userInitiated)
        try? FileManager.default.removeItem(at: url)
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: MeetingRecorder.sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func append(_ buffer: AVAudioPCMBuffer, hostTime: UInt64?) {
        queue.async { [self] in
            guard file != nil, let mono = convert(buffer) else { return }
            // Dónde debería caer este bloque según el reloj: si va adelantado respecto de lo
            // escrito (empezó tarde, hubo un hueco), se rellena con silencio.
            if let hostTime, hostTime > startHost {
                let expected = Int64(Self.seconds(fromHost: hostTime - startHost) * MeetingRecorder.sampleRate)
                let gap = expected - framesWritten
                if gap > Int64(MeetingRecorder.sampleRate * 0.05) { writeSilence(frames: gap) }
            }
            write(mono)
        }
    }

    private func write(_ mono: AVAudioPCMBuffer) {
        guard let file else { return }
        do { try file.write(from: mono) } catch {
            meetingLog.error("pista \(self.name, privacy: .public): no se pudo escribir: \(error.localizedDescription, privacy: .public)")
            return
        }
        framesWritten += Int64(mono.frameLength)
        let n = Int(mono.frameLength)
        guard n > 0 else { return }
        let p = mono.floatChannelData![0]
        var acc: Float = 0
        for i in 0..<n { acc += p[i] * p[i] }
        let rms = (acc / Float(n)).squareRoot()
        stateLock.withLock {
            _level = rms
            if rms > 0.003 { _signalSeconds += Double(n) / MeetingRecorder.sampleRate }
        }
    }

    private func writeSilence(frames: Int64) {
        var left = frames
        let block: AVAudioFrameCount = 48_000
        let buf = AVAudioPCMBuffer(pcmFormat: MeetingRecorder.trackFormat, frameCapacity: block)!
        while left > 0 {
            let n = AVAudioFrameCount(min(Int64(block), left))
            buf.frameLength = n
            memset(buf.floatChannelData![0], 0, Int(n) * MemoryLayout<Float>.size)
            try? file?.write(from: buf)
            framesWritten += Int64(n)
            left -= Int64(n)
        }
    }

    /// A 48 kHz mono. El conversor se mantiene entre bloques (el resampleo necesita
    /// continuidad) y se rehace si el formato de entrada cambia (cambió el micrófono).
    private func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let target = MeetingRecorder.trackFormat
        if input.format == target { return input }
        if converter == nil || converterInput != input.format {
            converter = AVAudioConverter(from: input.format, to: target)
            converterInput = input.format
            // Estéreo → mono promediando, no quedándose con el canal izquierdo.
            if input.format.channelCount > 1 { converter?.downmix = true }
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var consumed = false
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error || err != nil { return nil }
        return out
    }

    func close() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                file = nil   // AVAudioFile cierra y completa el encabezado al soltarse
                cont.resume()
            }
        }
    }

    static func seconds(fromHost delta: UInt64) -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(delta) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }
}
