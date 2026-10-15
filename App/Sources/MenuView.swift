import AVFoundation
import LoroCore
import LoroKit
import SwiftUI

/// Lo que se abre al hacer clic en el lorito de la barra.
struct MenuView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 8)
            if !state.hasAccessibility { permissionBanner }
            historySection
            Divider().padding(.vertical, 8)
            footer
        }
        .padding(14)
        .frame(width: 340)
        // Nido escribe en el mismo historial: al abrir el menú se relee del disco.
        .onAppear { state.reloadHistoryIfChanged() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "bird.fill").font(.title2).foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 2) {
                Text("Loro").font(.headline)
                Text(statusLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                state.status == .recording ? state.finishRecording() : state.startRecording()
            } label: {
                Image(systemName: state.status == .recording ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.title)
                    .foregroundStyle(state.status == .recording ? .red : .teal)
            }
            .buttonStyle(.plain)
            .disabled(state.enginePhase != .ready)
            .help(state.status == .recording ? "Parar" : "Grabar (o mantén \(state.settings.hotkey.label))")
        }
    }

    private var statusLine: String {
        switch state.status {
        case .idle: "Mantén \(state.settings.hotkey.label) y habla"
        default: state.status.label
        }
    }

    private var permissionBanner: some View {
        Banner(icon: "hand.raised.fill", tint: .orange,
               text: "Falta el permiso de Accesibilidad para el atajo global y para pegar.",
               action: ("Abrir Ajustes", { HotkeyMonitor.openAccessibilitySettings() }))
    }

    @ViewBuilder
    private var historySection: some View {
        if state.history.isEmpty {
            Text("Todavía no hay dictados. Mantén \(state.settings.hotkey.label), habla, suelta.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        } else {
            Text("Recientes").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(state.history.prefix(8)) { item in
                        HistoryRow(item: item)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
    }

    private var footer: some View {
        HStack {
            Button("Abrir Loro") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            Spacer()
            Button { openSettings(); NSApp.activate() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.plain).help("Ajustes")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.plain).help("Salir")
        }
        .font(.callout)
    }
}

struct HistoryRow: View {
    @Environment(AppState.self) private var state
    let item: AppState.HistoryItem
    var showStages = false
    @State private var copied = false
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if item.isEmpty {
                    // Dictado que no produjo texto: la fila existe para poder oír el audio
                    // y entender por qué salió vacío (micrófono mudo, ruido).
                    Label("Sin texto — el micrófono no captó voz", systemImage: "mic.slash")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(item.text).font(.callout).lineLimit(3)
                }
                Text("\(item.date.formatted(date: .abbreviated, time: .shortened)) · \(Int(item.duration.rounded()))s · \(item.engine.shortName)\(item.source == "Dictado" ? "" : " · \(item.source)")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if showStages, let url = item.audioURL, FileManager.default.fileExists(atPath: url.path) {
                Button { AudioPlayback.shared.toggle(url) } label: {
                    Image(systemName: AudioPlayback.shared.playing == url ? "stop.circle" : "play.circle").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).help("Escuchar el audio")
                .contextMenu { Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
            }
            if showStages, item.audioURL.map({ FileManager.default.fileExists(atPath: $0.path) }) == true {
                if state.retranscribing.contains(item.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button { state.retranscribeWithWhisper(item) } label: {
                        Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Re-transcribir con Whisper (forzado a español) y copiar")
                }
            }
            if showStages, item.stages != nil {
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).help("Ver etapas")
            }
            if !item.isEmpty {
                Button {
                    Paster.copyOnly(item.text)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").foregroundStyle(copied ? .green : .secondary)
                }
                .buttonStyle(.plain).help("Copiar")
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .bottom) { EmptyView() }
        .background {
            if expanded, let st = item.stages { Color.clear.preference(key: StagesKey.self, value: st) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if expanded, let st = item.stages { StagesView(stages: st).padding(.top, 6) }
        }
    }
}

/// Reproduce el audio guardado de un dictado. Uno a la vez.
@Observable @MainActor
final class AudioPlayback: NSObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayback()
    private(set) var playing: URL?
    private var player: AVAudioPlayer?

    func toggle(_ url: URL) {
        if playing == url { player?.stop(); player = nil; playing = nil; return }
        player?.stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.delegate = self; p.play()
        player = p; playing = url
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playing = nil; self.player = nil }
    }
}

struct StagesKey: PreferenceKey {
    static let defaultValue: DictationStages? = nil
    static func reduce(value: inout DictationStages?, nextValue: () -> DictationStages?) { value = nextValue() ?? value }
}

/// Las etapas del texto, marcando cuál se entregó.
struct StagesView: View {
    let stages: DictationStages
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let d = stages.driftedRaw {
                StageRow(name: "Descartado (inglés)", key: "drifted", text: d, delivered: stages.delivered)
            }
            StageRow(name: "Motor (crudo)", key: "raw", text: stages.raw, delivered: stages.delivered)
            if stages.dictionary != stages.raw {
                StageRow(name: "Diccionario", key: "dictionary", text: stages.dictionary, delivered: stages.delivered)
            }
            if stages.filler != stages.dictionary {
                StageRow(name: "Sin muletillas", key: "filler", text: stages.filler, delivered: stages.delivered)
            }
        }
        .font(.caption)
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct StageRow: View {
    let name: String
    let key: String
    let text: String
    let delivered: String
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(name).foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
            Text(text).textSelection(.enabled)
            if key == delivered { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Entregado") }
        }
    }
}

struct Banner: View {
    let icon: String
    let tint: Color
    let text: String
    let action: (String, () -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(text).font(.caption)
                if let action { Button(action.0, action: action.1).font(.caption).controlSize(.small) }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.bottom, 8)
    }
}
