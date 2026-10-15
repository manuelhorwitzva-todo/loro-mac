import CoreAudio

/// Lo justo de CoreAudio para saber por dónde entra el audio y no grabar por Bluetooth.
enum InputDevices {
    /// Si la entrada por defecto es un audífono Bluetooth que nadie está usando, deja el
    /// micrófono integrado del Mac como entrada del sistema y devuelve la anterior, para
    /// reponerla con `restoreDefaultInput`. nil si no cambió nada: la entrada no es Bluetooth,
    /// el audífono ya está en una llamada, o no hay micrófono integrado (tapa cerrada, Mac mini).
    ///
    /// Se cambia la entrada del sistema y no el dispositivo del motor: AVAudioEngine abre la
    /// entrada por defecto apenas se le pide el nodo, y fijarle otro dispositivo después no
    /// evita que el audífono cambie de modo (12-oct: grabación de 0,00 s y error -10868).
    static func switchToBuiltInMicIfBluetooth() -> AudioDeviceID? {
        guard let current = defaultInput(), isBluetooth(current), !isRunning(current),
              let builtIn = all().first(where: { transport($0) == kAudioDeviceTransportTypeBuiltIn && hasInput($0) }),
              setDefaultInput(builtIn) else { return nil }
        return current
    }

    /// Repone la entrada que había antes de `switchToBuiltInMicIfBluetooth`, salvo que el
    /// usuario haya elegido otra entremedio o el audífono ya no esté.
    static func restoreDefaultInput(_ previous: AudioDeviceID) {
        guard let current = defaultInput(), transport(current) == kAudioDeviceTransportTypeBuiltIn,
              all().contains(previous) else { return }
        _ = setDefaultInput(previous)
    }

    /// La entrada por defecto, solo si es un audífono Bluetooth.
    static func bluetoothDefaultInput() -> AudioDeviceID? {
        defaultInput().flatMap { isBluetooth($0) ? $0 : nil }
    }

    /// Formato en que el dispositivo entrega su entrada a un IOProc.
    static func inputFormat(of device: AudioDeviceID) -> AudioStreamBasicDescription? {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = address(kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeInput)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &format) == noErr,
              format.mSampleRate > 0, format.mChannelsPerFrame > 0 else { return nil }
        return format
    }

    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func defaultInput() -> AudioDeviceID? {
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    private static func setDefaultInput(_ device: AudioDeviceID) -> Bool {
        var id = device
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        return AudioObjectSetPropertyData(system, &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr
    }

    private static func isRunning(_ device: AudioDeviceID) -> Bool {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func all() -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func transport(_ device: AudioDeviceID) -> UInt32 {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = address(kAudioDevicePropertyTransportType)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    private static func isBluetooth(_ device: AudioDeviceID) -> Bool {
        let t = transport(device)
        return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func hasInput(_ device: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}
