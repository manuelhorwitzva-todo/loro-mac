@preconcurrency import AVFoundation
import Foundation

/// Audio en el formato canónico que consumen ambos motores: 16 kHz, mono, Float32.
/// Tener UN formato interno es lo que hace que micrófono y archivos compartan pipeline.
public struct AudioClip: Sendable, Equatable {
    public static let sampleRate: Double = 16_000
    public var samples: [Float]

    public init(samples: [Float]) { self.samples = samples }

    public var duration: TimeInterval { Double(samples.count) / Self.sampleRate }

    public static var canonicalFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    }

    /// Convierte los samples a un AVAudioPCMBuffer (lo necesita el motor de Apple).
    public func pcmBuffer() -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: Self.canonicalFormat, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }

    /// Guarda el clip como WAV 16 kHz mono Int16 (~32 KB por segundo). Sirve para auditar
    /// motores sobre dictados reales: `loro bench archivo.wav`.
    public func write(to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: pcmBuffer())
    }

    /// Lee cualquier archivo que AVFoundation entienda (wav, m4a, mp3, aiff, caf, mp4...) y lo convierte al formato canónico.
    public static func load(url: URL) throws -> AudioClip {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard let raw = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: max(frames, 1)) else {
            throw LoroError.audio("No pude reservar buffer para \(url.lastPathComponent)")
        }
        try file.read(into: raw)
        return try resample(raw)
    }

    /// Resamplea un buffer cualquiera a 16 kHz mono. Se usa tanto para archivos como para el tap del micrófono.
    public static func resample(_ input: AVAudioPCMBuffer) throws -> AudioClip {
        let target = canonicalFormat
        if input.format.sampleRate == target.sampleRate, input.format.channelCount == 1, input.format.commonFormat == .pcmFormatFloat32 {
            return AudioClip(samples: Array(UnsafeBufferPointer(start: input.floatChannelData![0], count: Int(input.frameLength))))
        }
        guard let converter = AVAudioConverter(from: input.format, to: target) else {
            throw LoroError.audio("No hay conversor de \(input.format) a 16 kHz mono")
        }
        let ratio = target.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw LoroError.audio("No pude reservar buffer de salida")
        }
        var consumed = false
        var convError: NSError?
        let status = converter.convert(to: out, error: &convError) { _, outStatus in
            if consumed { outStatus.pointee = .endOfStream; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }
        if let convError { throw convError }
        if status == .error { throw LoroError.audio("Falló la conversión de audio") }
        return AudioClip(samples: Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))))
    }

    /// Nivel RMS del clip, útil para detectar silencio o mostrar un medidor.
    public var rms: Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }
}

public enum LoroError: Error, LocalizedError, Sendable {
    case audio(String)
    case engine(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .audio(let s), .engine(let s), .unavailable(let s): return s
        }
    }
}
