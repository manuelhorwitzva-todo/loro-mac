import CoreAudio
import Foundation
import os

private let mediaLog = Logger(subsystem: "cl.manulit0.loro", category: "media")

/// Pausa lo que esté sonando (Spotify, un video en el navegador…) mientras se dicta y lo
/// reanuda al terminar. Solo reanuda si fue Loro quien pausó: nunca echa a andar música que
/// estaba detenida. Lo usa `DictationSession`, así que Loro y Nido se comportan igual.
///
/// Desde macOS 15.4 MediaRemote solo le responde a procesos de Apple ("Operation not
/// permitted" para el resto), así que se le pregunta a través de osascript. Si algo falla
/// no pasa nada: el dictado sigue igual, con el audio sonando.
@MainActor
public final class MediaPause {
    public static let defaultsKey = "pauseMedia"
    public static var enabled: Bool { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }

    /// Loro dejó algo en pausa y le toca reanudarlo.
    private var owned = false
    /// Salida de audio y su sample rate al pausar: así suena la música fuera de manos libres.
    private var outputBefore: (device: AudioDeviceID, rate: Float64)?
    private var resuming: Task<Void, Never>?
    private let commands = Commands()

    public init() {}

    /// Pausa y espera a que la orden se haya aplicado, para abrir el micrófono con la música ya
    /// detenida. ~0,2 s con osascript.
    public func pause() async {
        guard Self.enabled else { return }
        if let resuming {
            // Dictado nuevo mientras se esperaba para reanudar: la música sigue en pausa, se deja así.
            resuming.cancel()
            self.resuming = nil
        }
        guard !owned else { return }
        let output = Self.output()
        if await commands.send("pause") == "1" {
            owned = true
            outputBefore = output
            mediaLog.info("música en pausa para dictar")
        }
    }

    /// Reanuda lo que Loro pausó, cuando el audífono ya salió de manos libres: con AirPods Pro
    /// tarda ~2,3 s en volver de 24 a 48 kHz (16-oct), y reanudar antes suena como llamada.
    /// No reanuda si cambió la salida (se sacó los audífonos): macOS tampoco lo hace.
    public func resume() {
        guard owned, resuming == nil else { return }
        let before = outputBefore
        resuming = Task { [weak self] in
            let deadline = ContinuousClock.now + Self.settleTimeout
            while ContinuousClock.now < deadline, !Task.isCancelled, !Self.settled(before) {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let self, !Task.isCancelled else { return }
            owned = false
            resuming = nil
            if let before, Self.output()?.device != before.device {
                mediaLog.notice("la salida de audio cambió durante el dictado: no se reanuda la música")
                return
            }
            if !Self.settled(before) { mediaLog.notice("el audífono no volvió del modo llamada a tiempo: se reanuda igual") }
            _ = await commands.send("play")
        }
    }

    static let settleTimeout: Duration = .seconds(4)

    /// La salida está como antes de dictar: mismo dispositivo y mismo sample rate.
    private nonisolated static func settled(_ before: (device: AudioDeviceID, rate: Float64)?) -> Bool {
        guard let before, let now = output() else { return true }
        return now.device != before.device || now.rate >= before.rate
    }

    private nonisolated static func output() -> (device: AudioDeviceID, rate: Float64)? {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var rate: Float64 = 0
        guard read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &device),
              device != kAudioObjectUnknown,
              read(device, kAudioDevicePropertyNominalSampleRate, &rate) else { return nil }
        return (device, rate)
    }

    private nonisolated static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }

    /// Las órdenes van de a una y en orden: un "play" atrasado no puede caer después del "pause"
    /// del dictado siguiente.
    private actor Commands {
        /// "pause" pausa solo si hay algo sonando y devuelve "1" si pausó; "play" reanuda.
        private static let script = """
        ObjC.import('Foundation');
        function run(argv) {
          $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework').load;
          ObjC.bindFunction('MRMediaRemoteSendCommand', ['bool', ['int', 'id']]);
          if (argv[0] === 'pause' && !$.NSClassFromString('MRNowPlayingRequest').localIsPlaying) return '0';
          $.MRMediaRemoteSendCommand(argv[0] === 'play' ? 0 : 1, $());
          return '1';
        }
        """

        func send(_ command: String) -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-l", "JavaScript", "-e", Self.script, command]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return "" }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
