import AVFoundation
import LoroCore
import LoroKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @State private var appleLocales: [Locale] = []
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage(DictationSession.bluetoothMicKey) private var useBluetoothMic = false
    @AppStorage(MediaPause.defaultsKey) private var pauseMedia = false

    var body: some View {
        @Bindable var state = state
        Form {
            Section("Atajo") {
                Picker("Tecla", selection: $state.settings.hotkey) {
                    ForEach(Hotkey.allCases) { Text($0.label).tag($0) }
                }
                if let w = state.settings.hotkey.warning {
                    Text(w).font(.caption).foregroundStyle(.orange)
                }
                Picker("Modo", selection: $state.settings.hotkeyMode) {
                    ForEach(LoroSettings.HotkeyMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Toggle("Pegar el texto donde esté el cursor", isOn: $state.settings.pasteAfterTranscribe)
                Toggle("Esperar Enter antes de pegar (Esc lo deja solo en el portapapeles)", isOn: $state.settings.confirmWithEnter)
                    .disabled(!state.settings.pasteAfterTranscribe)
                Toggle("Sonidos al empezar y terminar", isOn: $state.settings.playSounds)
                Toggle("Pausar la música y los videos mientras dictas", isOn: $pauseMedia)
            }

            Section("Micrófono") {
                LabeledContent("Ruido de fondo") {
                    HStack {
                        Text(AppState.micModeName(AVCaptureDevice.preferredMicrophoneMode)).foregroundStyle(.secondary)
                        if state.micModeSessionActive {
                            Button("Listo") { state.endMicModeSelection() }
                        } else {
                            Button("Cambiar…") { state.beginMicModeSelection() }
                        }
                    }
                }
                if state.micModeSessionActive {
                    Text("Micrófono abierto. Arriba a la derecha se abrió el Centro de control: elige “Aislamiento de voz” y luego aprieta Listo. Si no se abrió, haz clic en el ícono naranja del micrófono en la barra de menú.")
                        .font(.caption).foregroundStyle(.teal)
                } else {
                    Text("Elige “Aislamiento de voz”: macOS filtra ruido y voces lejanas antes de que el audio llegue a Loro.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Con audífonos Bluetooth, dictar con el micrófono del audífono", isOn: $useBluetoothMic)
                Text("Apagado, Loro graba con el micrófono del Mac y la música sigue sonando normal. Encendido, el audífono pasa a modo llamada mientras dictas y el audio se oye peor.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Motor de transcripción") {
                Picker("Motor", selection: $state.settings.engine) {
                    ForEach(EngineKind.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.radioGroup)
                if state.settings.engine == .parakeet {
                    Text("NVIDIA Parakeet v3: rápido, pero no se le puede fijar el idioma y en dictados en español con términos en inglés se desvía al inglés o al italiano (~la mitad de las veces en la auditoría del 10-sep). Cuando pasa, Loro re-transcribe con Whisper. Descarga ~470 MB una vez.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if state.settings.engine == .whisper {
                    Picker("Modelo", selection: $state.settings.whisperModel) {
                        ForEach(WhisperEngine.availableModels, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    Picker("Idioma principal", selection: $state.settings.whisperLanguage) {
                        Text("Español").tag("es")
                        Text("English").tag("en")
                        Text("Auto-detectar").tag("auto")
                    }
                    Text("Con el idioma fijo no se desvía y es el que mejor escribe la jerga en inglés (sync, merge, mockup), pero es ~5× más lento que Apple y a veces se salta frases.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Idioma", selection: $state.settings.appleLocale) {
                        ForEach(appleLocales, id: \.identifier) { Text(label(for: $0)).tag($0.identifier) }
                    }
                    Text("Recomendado. El más rápido, sin descargas, no se desvía de idioma y no se salta frases. Su punto débil es la jerga en inglés (sync → “zinc”, card → “carta”): lo que se repite, corrígelo en el Diccionario.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Estado") { Text(engineStatus).foregroundStyle(.secondary) }
            }

            Section("Limpieza del texto") {
                Toggle("Quitar muletillas (eh, o sea, como que, um…)", isOn: $state.settings.fillerFilter)
                Text("Reglas fijas, instantáneo, nunca borra contenido.").font(.caption).foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Abrir Loro al iniciar sesión", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
                Toggle("Guardar historial (se borra a los 7 días)", isOn: $state.settings.keepHistory)
                Toggle("Guardar también el audio de cada dictado (para auditar el motor)", isOn: $state.settings.keepAudio)
                    .disabled(!state.settings.keepHistory)
                LabeledContent("Accesibilidad") {
                    if state.hasAccessibility { Label("Concedido", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    else { Button("Abrir Ajustes de Privacidad") { HotkeyMonitor.openAccessibilitySettings() } }
                }
                LabeledContent("Micrófono") {
                    Label(state.hasMicrophone ? "Concedido" : "Sin permiso", systemImage: state.hasMicrophone ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(state.hasMicrophone ? .green : .red)
                }
                LabeledContent("Modelos") {
                    Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([ModelStore.root]) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 720)
        .navigationTitle("Ajustes de Loro")
        .task {
            let locales = await AppleSpeechEngine.supportedLocales
            appleLocales = locales.sorted { label(for: $0) < label(for: $1) }
        }
    }

    private var engineStatus: String {
        switch state.enginePhase {
        case .idle: "—"
        case .downloading(let p): "Descargando \(Int(p * 100))%"
        case .loading: "Cargando…"
        case .ready: "Listo"
        case .failed(let e): "Error: \(e)"
        }
    }

    private func label(for locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}
