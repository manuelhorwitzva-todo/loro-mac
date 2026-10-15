import AVFoundation
import LoroCore
import LoroKit
import SwiftUI

/// Ventana principal: todo lo que la barra de menú no alcanza a mostrar.
struct MainWindow: View {
    enum Section: String, CaseIterable, Identifiable {
        case home = "Inicio", files = "Archivos", history = "Historial", dictionary = "Diccionario"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .home: "bird.fill"
            case .files: "waveform.badge.plus"
            case .history: "clock"
            case .dictionary: "character.book.closed"
            }
        }
    }

    @Environment(AppState.self) private var state
    @Environment(\.openSettings) private var openSettings
    @State private var section: Section = .home

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { s in
                Label(s.rawValue, systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) {
                Button { openSettings() } label: {
                    Label("Ajustes", systemImage: "gearshape").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            switch section {
            case .home: HomeView().navigationTitle("Inicio")
            case .files: FilesView()
            case .history: HistoryView()
            case .dictionary: DictionaryView()
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear { if !state.settings.onboardingDone { section = .home } }
    }
}

// MARK: - Inicio / onboarding

struct HomeView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Loro").font(.largeTitle.bold())
                        Text("Dictado por voz, 100% en este Mac. Mantén \(state.settings.hotkey.label), habla, suelta.")
                            .foregroundStyle(.secondary)
                    }
                }

                GroupBox("Lista de chequeo") {
                    VStack(alignment: .leading, spacing: 10) {
                        CheckRow(ok: state.hasMicrophone, title: "Micrófono",
                                 detail: state.hasMicrophone ? "Concedido" : "Sin permiso: Ajustes del Sistema → Privacidad y seguridad → Micrófono",
                                 action: state.hasMicrophone ? nil : ("Abrir", { open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") }))
                        CheckRow(ok: state.hasAccessibility, title: "Accesibilidad",
                                 detail: state.hasAccessibility ? "Concedido: atajo global y pegado activos" : "Necesario para el atajo global y para pegar donde está el cursor",
                                 action: state.hasAccessibility ? nil : ("Abrir", { HotkeyMonitor.openAccessibilitySettings() }))
                        CheckRow(ok: state.enginePhase == .ready, title: "Motor \(state.settings.engine.shortName)",
                                 detail: engineDetail, action: nil)
                        CheckRow(ok: micModeOK, title: "Ruido de fondo",
                                 detail: micModeOK ? "Aislamiento de voz activo" : "Recomendado: modo “Aislamiento de voz” del micrófono (Ajustes → Micrófono → Cambiar…)",
                                 action: nil)
                    }
                    .padding(6)
                }

                GroupBox("Prueba") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Haz clic en el campo, mantén \(state.settings.hotkey.label) y habla.")
                            .font(.callout).foregroundStyle(.secondary)
                        TextEditor(text: $state.scratchText)
                            .font(.body).frame(minHeight: 90)
                            .scrollContentBackground(.hidden)
                            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                        if !state.lastTranscript.isEmpty {
                            Text("Último dictado: “\(state.lastTranscript)”").font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                    .padding(6)
                }

                GroupBox("Consejos") {
                    VStack(alignment: .leading, spacing: 8) {
                        Tip(icon: "globe", text: "Mezcla español e inglés en la misma frase; lo entiende igual.")
                        Tip(icon: "character.book.closed", text: "Nombres que salen mal van al Diccionario y se corrigen solos.")
                        Tip(icon: "waveform.badge.plus", text: "Arrastra audios o videos a Archivos para transcribir reuniones.")
                        Tip(icon: "keyboard", text: "Esc cancela. Si una app no acepta el pegado, el texto queda en el portapapeles.")
                    }
                    .padding(6)
                }

                if !state.settings.onboardingDone {
                    Button("Listo, entendido") { state.settings.onboardingDone = true }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    private var engineDetail: String {
        switch state.enginePhase {
        case .ready: "Listo"
        case .downloading(let p): "Descargando modelo \(Int(p * 100))% (una sola vez)"
        case .loading: "Compilando el modelo para el Neural Engine (solo la primera vez, unos minutos)"
        case .failed(let e): "Error: \(e)"
        case .idle: "Esperando"
        }
    }

    private var micModeOK: Bool { AVCaptureDevice.preferredMicrophoneMode == .voiceIsolation }

    private func open(_ url: String) { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }
}

struct CheckRow: View {
    let ok: Bool
    let title: String
    let detail: String
    let action: (String, () -> Void)?
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? .green : .secondary).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let action { Button(action.0, action: action.1).controlSize(.small) }
        }
    }
}

struct Tip: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(.teal)
            Text(text).font(.callout)
        }
    }
}

// MARK: - Historial

struct HistoryView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            statsHeader
            Divider()
            Group {
                if state.history.isEmpty {
                    ContentUnavailableView("Sin dictados esta semana", systemImage: "clock",
                                           description: Text("Los dictados se guardan 7 días. Las estadísticas de arriba quedan para siempre."))
                } else {
                    List(state.history) { item in HistoryRow(item: item, showStages: true) }
                        .listStyle(.inset)
                }
            }
        }
        .navigationTitle("Historial")
        // El historial también lo escribe Nido, así que se relee al abrir la vista.
        .onAppear { state.reloadHistoryIfChanged() }
        .toolbar { ToolbarItem { Button("Vaciar") { HistoryStore.clearHistory(); state.reloadHistory() }.disabled(state.history.isEmpty) } }
    }

    private var statsHeader: some View {
        let week = state.stats.week()
        let s = state.stats
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                StatTile(title: "Esta semana", value: "\(week.dictations)", unit: "dictados")
                StatTile(title: "Palabras", value: "\(week.words)", unit: "esta semana")
                StatTile(title: "Hablado", value: Self.minutes(week.seconds), unit: "esta semana")
                StatTile(title: "Ahorrado", value: Self.minutes(LoroStats.savedSeconds(words: week.words, spoken: week.seconds)), unit: "vs. teclear")
            }
            HStack(spacing: 6) {
                Text("Total: \(s.totalDictations) dictados · \(s.totalWords) palabras · \(Self.minutes(s.totalSeconds)) hablado · \(Self.minutes(LoroStats.savedSeconds(words: s.totalWords, spoken: s.totalSeconds))) ahorrado")
                if s.streak() > 1 { Text("· racha de \(s.streak()) días") }
                if let fav = s.favoriteEngine, s.byEngine.count > 1 { Text("· motor favorito: \(fav.shortName)") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
    }

    static func minutes(_ seconds: TimeInterval) -> String {
        let m = Int(seconds / 60)
        if m < 1 { return "\(Int(seconds)) s" }
        if m < 60 { return "\(m) min" }
        return String(format: "%.1f h", seconds / 3600)
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let unit: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded))
            Text(unit).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Diccionario

struct DictionaryView: View {
    @Environment(AppState.self) private var state
    @State private var newKind: DictionaryEntry.Kind = .term
    @State private var newWrite = ""
    @State private var newHear = ""
    @State private var selection: UUID?

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $newKind) {
                    Text("Nombre").tag(DictionaryEntry.Kind.term)
                    Text("Corrección").tag(DictionaryEntry.Kind.correction)
                }
                .labelsHidden().frame(width: 130)
                if newKind == .correction {
                    TextField("Cuando escuche…", text: $newHear).textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                }
                TextField(newKind == .term ? "Nombre tal como se escribe" : "Escribir…", text: $newWrite)
                    .textFieldStyle(.roundedBorder).onSubmit(add)
                Button("Agregar", action: add).disabled(!canAdd)
            }
            .padding(12)
            Divider()
            Table(state.dictionary, selection: $selection) {
                TableColumn("Activo") { e in
                    Toggle("", isOn: binding(e).isEnabled).labelsHidden()
                }.width(50)
                TableColumn("Tipo") { e in Text(e.kind == .term ? "Nombre" : "Corrección").foregroundStyle(.secondary) }.width(90)
                TableColumn("Cuando escuche") { e in Text(e.kind == .correction ? e.hear : "—").foregroundStyle(e.kind == .correction ? .primary : .secondary) }
                TableColumn("Escribir") { e in Text(e.write) }
            }
            Divider()
            HStack {
                Text("\(state.dictionary.count) entradas · se aplican después de transcribir, sin distinguir mayúsculas ni tildes, palabra completa.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Eliminar") { if let id = selection { state.dictionary.removeAll { $0.id == id }; selection = nil } }
                    .disabled(selection == nil)
            }
            .padding(10)
        }
        .navigationTitle("Diccionario")
    }

    private var canAdd: Bool {
        !newWrite.trimmingCharacters(in: .whitespaces).isEmpty && (newKind == .term || !newHear.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func add() {
        guard canAdd else { return }
        let w = newWrite.trimmingCharacters(in: .whitespaces)
        let h = newHear.trimmingCharacters(in: .whitespaces)
        state.dictionary.insert(newKind == .term ? .term(w) : .correction(h, w), at: 0)
        newWrite = ""; newHear = ""
    }

    private func binding(_ e: DictionaryEntry) -> Binding<DictionaryEntry> {
        Binding(
            get: { state.dictionary.first { $0.id == e.id } ?? e },
            set: { new in if let i = state.dictionary.firstIndex(where: { $0.id == e.id }) { state.dictionary[i] = new } }
        )
    }
}
