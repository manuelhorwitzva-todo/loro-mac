import CoreAudio
import Foundation

/// Pausa lo que esté sonando (Spotify, un video en el navegador…) mientras se dicta y lo
/// reanuda al terminar. Solo reanuda si fue Loro quien pausó: nunca echa a andar música
/// que estaba detenida.
///
/// Desde macOS 15.4 MediaRemote solo le responde a procesos de Apple ("Operation not
/// permitted" para el resto), así que se le pregunta a través de osascript. Si algo falla
/// no pasa nada: el dictado sigue igual, con el audio sonando.
@MainActor
final class MediaPause {
    static let defaultsKey = "pauseMedia"
    static var enabled: Bool { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }

    /// Cola de órdenes: el valor es true si Loro dejó algo en pausa. Encadenadas para que un
    /// dictado corto no mande el "play" antes de que termine el "pause".
    private var chain: Task<Bool, Never>?

    func pause() {
        guard Self.enabled else { return }
        let previous = chain
        chain = Task.detached {
            if await previous?.value == true { return true }
            return Self.run("pause") == "1"
        }
    }

    func resume() {
        let previous = chain
        chain = Task.detached {
            guard await previous?.value == true else { return false }
            // Si se dictó por el audífono, sigue un momento en manos libres: reanudar ahí hace
            // sonar la música por el canal de llamada. Se espera a que vuelva (máx. 2 s).
            for _ in 0..<40 where Self.outputInCallMode() { try? await Task.sleep(for: .milliseconds(50)) }
            _ = Self.run("play")
            return false
        }
    }

    /// La salida por defecto es un audífono Bluetooth que todavía está en manos libres (16 kHz).
    private nonisolated static func outputInCallMode() -> Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var size = UInt32(MemoryLayout<T>.size)
            return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
        }
        var device = AudioDeviceID(kAudioObjectUnknown), transport: UInt32 = 0, rate: Float64 = 0
        guard read(system, kAudioHardwarePropertyDefaultOutputDevice, &device),
              read(device, kAudioDevicePropertyTransportType, &transport),
              transport == kAudioDeviceTransportTypeBluetooth,
              read(device, kAudioDevicePropertyNominalSampleRate, &rate) else { return false }
        return rate <= 16000
    }

    /// "pause" pausa solo si hay algo sonando y devuelve "1" si pausó; "play" reanuda.
    private nonisolated static let script = """
    ObjC.import('Foundation');
    function run(argv) {
      $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework').load;
      ObjC.bindFunction('MRMediaRemoteSendCommand', ['bool', ['int', 'id']]);
      if (argv[0] === 'pause' && !$.NSClassFromString('MRNowPlayingRequest').localIsPlaying) return '0';
      $.MRMediaRemoteSendCommand(argv[0] === 'play' ? 0 : 1, $());
      delay(0.2);
      return '1';
    }
    """

    private nonisolated static func run(_ command: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script, command]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
