@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os

let tapLog = Logger(subsystem: "cl.manulit0.loro", category: "system-audio")

/// Captura el audio que SALE de ciertas apps (el navegador de la reunión) con un Core Audio
/// tap: sin drivers virtuales y sin tocar lo que escuchas. Solo esas apps: Spotify o las
/// notificaciones no quedan en la grabación.
///
/// Cómo funciona: un tap (`CATapDescription`) se mete como entrada de un "aggregate device"
/// privado, y un IOProc de ese dispositivo recibe los buffers igual que si fuera un micrófono.
/// `bundleIDs` + `processRestoreEnabled` (macOS 26) hacen que una app que abre el audio
/// después de empezar (Meet conecta la llamada) entre sola al tap.
public final class SystemAudioCapture: @unchecked Sendable {
    /// Navegadores y apps de videollamada. Chrome y los Chromium sacan el audio desde su
    /// proceso "helper"; Safari desde el proceso GPU de WebKit.
    public static let meetingBundleIDs: [String] = [
        "com.google.Chrome", "com.google.Chrome.helper", "com.google.Chrome.helper.renderer",
        "com.apple.Safari", "com.apple.WebKit.GPU", "com.apple.WebKit.WebContent",
        "company.thebrowser.Browser", "company.thebrowser.browser.helper",
        "com.brave.Browser", "com.brave.Browser.helper",
        "com.microsoft.edgemac", "com.microsoft.edgemac.helper",
        "us.zoom.xos", "com.microsoft.teams2", "com.apple.FaceTime",
    ]

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "cl.manulit0.loro.system-audio", qos: .userInitiated)
    public private(set) var format: AVAudioFormat?
    private var description: CATapDescription?
    private var matchPrefixes: [String] = []
    private var tappedProcesses: [AudioObjectID] = []
    private var refresher: DispatchSourceTimer?

    public init() {}

    public var isRunning: Bool { procID != nil }

    /// `bundleIDs` vacío = todo el audio del sistema salvo Loro.
    public func start(bundleIDs: [String] = SystemAudioCapture.meetingBundleIDs,
                      onBuffer: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime?) -> Void) throws {
        guard procID == nil else { return }
        let desc: CATapDescription
        if bundleIDs.isEmpty {
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        } else {
            // Por objeto de proceso, no solo por bundle ID: medido el 5-nov, un tap armado solo
            // con `bundleIDs` pierde a Chrome cuando este cierra y reabre su salida de audio
            // tras unos segundos de silencio (la reunión sigue sonando y la pista queda muda).
            // Por eso además se revisa cada segundo qué procesos calzan (`refreshProcesses`).
            matchPrefixes = bundleIDs
            tappedProcesses = Self.matchingProcesses(prefixes: bundleIDs)
            desc = CATapDescription(stereoMixdownOfProcesses: tappedProcesses)
            desc.bundleIDs = bundleIDs
            desc.isProcessRestoreEnabled = true
        }
        desc.name = "Loro reunión"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(desc, &tap)
        guard err == noErr, tap != kAudioObjectUnknown else { throw LoroError.audio("No se pudo crear el tap de audio (\(err))") }
        tapID = tap

        // Formato que entrega el tap (típicamente 48 kHz estéreo Float32).
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        err = AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd)
        guard err == noErr, let fmt = AVAudioFormat(streamDescription: &asbd) else {
            stop(); throw LoroError.audio("No se pudo leer el formato del tap (\(err))")
        }
        format = fmt

        let outputUID = try Self.defaultOutputUID()
        let aggUID = UUID().uuidString
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Loro reunión",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg)
        guard err == noErr else { stop(); throw LoroError.audio("No se pudo crear el dispositivo de captura (\(err))") }
        aggregateID = agg

        var proc: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, queue) { _, inInputData, inInputTime, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: inInputData, deallocator: nil) else { return }
            // El buffer apunta a memoria del HAL que se recicla al volver: se copia.
            guard let copy = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: buffer.frameLength) else { return }
            copy.frameLength = buffer.frameLength
            let src = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for i in 0..<min(src.count, dst.count) {
                guard let s = src[i].mData, let d = dst[i].mData else { continue }
                memcpy(d, s, Int(min(src[i].mDataByteSize, dst[i].mDataByteSize)))
            }
            let time = AVAudioTime(hostTime: inInputTime.pointee.mHostTime)
            onBuffer(copy, time)
        }
        guard err == noErr, let proc else { stop(); throw LoroError.audio("No se pudo abrir la captura (\(err))") }
        procID = proc
        err = AudioDeviceStart(agg, proc)
        guard err == noErr else { stop(); throw LoroError.audio("No se pudo iniciar la captura (\(err))") }
        description = desc
        if !bundleIDs.isEmpty {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.refreshProcesses() }
            timer.resume()
            refresher = timer
        }
        tapLog.info("tap activo: \(fmt.sampleRate, format: .fixed(precision: 0)) Hz, \(fmt.channelCount) canales, \(self.tappedProcesses.count) procesos")
    }

    /// Si cambió el conjunto de procesos del navegador con audio (Chrome reabrió su salida,
    /// se abrió Meet en otra app), se actualiza el tap en vivo, sin cortar la grabación.
    private func refreshProcesses() {
        guard let description, tapID != kAudioObjectUnknown else { return }
        let now = Self.matchingProcesses(prefixes: matchPrefixes)
        guard Set(now) != Set(tappedProcesses) else { return }
        description.processes = now
        var desc: CATapDescription = description
        let size = UInt32(MemoryLayout<CATapDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let err = withUnsafeMutablePointer(to: &desc) { AudioObjectSetPropertyData(tapID, &addr, 0, nil, size, $0) }
        if err == noErr {
            tapLog.info("procesos del tap: \(self.tappedProcesses.count) → \(now.count)")
            tappedProcesses = now
        } else {
            tapLog.error("no se pudo actualizar el tap (\(err))")
        }
    }

    /// Objetos de proceso cuyo bundle ID empieza con alguno de los prefijos.
    static func matchingProcesses(prefixes: [String]) -> [AudioObjectID] {
        processObjects().filter { obj in prefixes.contains { obj.bundleID.hasPrefix($0) } }.map(\.id)
    }

    static func processObjects() -> [(id: AudioObjectID, bundleID: String)] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
            var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var cf: Unmanaged<CFString>?
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, &cf) == noErr, let cf else { return nil }
            return (id, cf.takeRetainedValue() as String)
        }
    }

    public func stop() {
        refresher?.cancel()
        refresher = nil
        if aggregateID != kAudioObjectUnknown, let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    static func defaultOutputUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        guard err == noErr else { throw LoroError.audio("No hay salida de audio (\(err))") }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        err = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid)
        guard err == noErr, let uid else { throw LoroError.audio("No se pudo leer la salida de audio (\(err))") }
        return uid.takeRetainedValue() as String
    }

    /// Bundle IDs de los procesos que tienen audio abierto ahora (para diagnosticar qué
    /// proceso de un navegador es el que suena).
    public static func audioProcesses() -> [(bundleID: String, output: Bool)] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
            var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var cf: Unmanaged<CFString>?
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, &cf) == noErr, let cf else { return nil }
            var running: UInt32 = 0
            s = UInt32(MemoryLayout<UInt32>.size)
            a.mSelector = kAudioProcessPropertyIsRunningOutput
            AudioObjectGetPropertyData(id, &a, 0, nil, &s, &running)
            return (cf.takeRetainedValue() as String, running != 0)
        }
    }
}

/// Permiso de "Grabación de audio del sistema". No hay API pública para consultarlo: sin él,
/// el tap se crea igual y entrega silencio sin ningún error. Se consulta TCC directo (la misma
/// vía que usan las apps de grabación fuera del App Store); si no está disponible, `nil`.
public enum SystemAudioPermission {
    public enum State: Sendable { case granted, denied, unknown }

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
    private static let service = "kTCCServiceAudioCapture" as CFString

    nonisolated(unsafe) private static let tcc: UnsafeMutableRawPointer? = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    public static var state: State {
        guard let tcc, let sym = dlsym(tcc, "TCCAccessPreflight") else { return .unknown }
        let preflight = unsafeBitCast(sym, to: Preflight.self)
        switch preflight(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown   // 2 = todavía no se ha preguntado
        }
    }

    /// Muestra el diálogo del sistema si todavía no se ha preguntado.
    public static func request() async -> Bool {
        guard let tcc, let sym = dlsym(tcc, "TCCAccessRequest") else { return false }
        let req = unsafeBitCast(sym, to: Request.self)
        return await withCheckedContinuation { cont in
            req(service, nil) { granted in cont.resume(returning: granted) }
        }
    }

    public static func openSettings() -> URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
    }
}
