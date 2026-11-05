import LoroCore
import LoroKit
import SwiftUI

/// Bloque "Reunión" del menú de la barra: el botón para grabar y las últimas reuniones.
struct MeetingSection: View {
    @Environment(AppState.self) private var state
    private var meeting: MeetingController { state.meeting }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "person.2.wave.2.fill").foregroundStyle(meeting.isRecording ? .red : .teal)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Reunión").font(.callout.weight(.semibold))
                    Text(statusLine).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(meeting.isRecording ? "Terminar" : "Grabar reunión") { meeting.toggle() }
                    .controlSize(.small)
                    .tint(meeting.isRecording ? .red : nil)
                    .buttonStyle(.borderedProminent)
                    .disabled(!meeting.canStart && !meeting.isRecording)
            }
            if let p = meeting.transcribing {
                HStack(spacing: 6) {
                    Text("Transcribiendo la última reunión…").font(.caption2).foregroundStyle(.secondary)
                    ProgressView(value: p).controlSize(.small)
                }
            }
            if meeting.isRecording {
                Text("Avisa a los demás que estás grabando.").font(.caption2).foregroundStyle(.orange)
            }
            if meeting.permission == .denied || (meeting.isRecording && meeting.othersSilentWarning) {
                Banner(icon: "speaker.slash.fill", tint: .orange,
                       text: meeting.permission == .denied
                           ? "Loro no tiene permiso para grabar el audio de la reunión. Actívalo en Grabación de audio del sistema."
                           : "No llega audio de la reunión. Si los demás están hablando, falta el permiso de Grabación de audio del sistema.",
                       action: ("Abrir Ajustes", { meeting.openPermissionSettings() }))
            }
            if case .error(let e) = meeting.phase {
                Banner(icon: "exclamationmark.triangle.fill", tint: .red, text: e, action: ("Ok", { meeting.dismissError() }))
            }
            ForEach(meeting.meetings.prefix(3)) { m in MeetingRow(meeting: m) }
        }
    }

    private var statusLine: String {
        switch meeting.phase {
        case .idle: "Graba tu micrófono y el audio de la llamada"
        case .recording: "Grabando · tú y los demás en pistas separadas"
        case .saving: "Guardando…"
        case .error: "No se pudo grabar"
        }
    }
}

struct MeetingRow: View {
    @Environment(AppState.self) private var state
    let meeting: StoredMeeting

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.title).font(.caption).lineLimit(1)
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if meeting.transcriptURL != nil {
                Button { state.meeting.openTranscript(meeting) } label: { Image(systemName: "doc.text") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Abrir la transcripción")
            }
            Button { AudioPlayback.shared.toggle(meeting.mixURL) } label: {
                Image(systemName: AudioPlayback.shared.playing == meeting.mixURL ? "stop.circle" : "play.circle")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Escuchar")
            Button { state.meeting.reveal(meeting) } label: { Image(systemName: "folder") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Mostrar en Finder")
        }
    }

    private var detail: String {
        var parts = [MeetingTranscriber.clock(meeting.duration)]
        if meeting.systemSignalSeconds < 1 { parts.append("sin audio de los demás") }
        if let h = meeting.hookStatus { parts.append("envío: \(h)") }
        return parts.joined(separator: " · ")
    }
}

/// Ajustes de reuniones (pestaña en Ajustes).
struct MeetingSettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var meeting = state.meeting
        Group {
            Section {
                Toggle("Grabar solo el audio de navegadores y apps de videollamada", isOn: $meeting.settings.onlyMeetingApps)
                Text(meeting.settings.onlyMeetingApps
                     ? "Chrome, Safari, Arc, Brave, Edge, Zoom, Teams y FaceTime. La música y las notificaciones no quedan grabadas."
                     : "Todo lo que suene en el Mac, salvo Loro.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Transcribir en este Mac al terminar", isOn: $meeting.settings.transcribeLocally)
                Picker("Guardar reuniones", selection: $meeting.settings.keepDays) {
                    Text("7 días").tag(7); Text("30 días").tag(30); Text("90 días").tag(90); Text("Siempre").tag(0)
                }
            } header: { Text("Reuniones") }

            Section {
                TextField("Comando", text: $meeting.settings.onFinishCommand, prompt: Text("~/bin/subir-reunion.sh"), axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                Text("Se corre con zsh al terminar cada reunión. Recibe LORO_MEETING_MIX, LORO_MEETING_MIC, LORO_MEETING_OTHERS, LORO_MEETING_TRANSCRIPT, LORO_MEETING_START, LORO_MEETING_END y LORO_MEETING_DIR. Sirve para mandar la reunión a otro sistema.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Reuniones: al terminar") }

            Section {
                HStack {
                    Text("Grabación de audio del sistema")
                    Spacer()
                    Text(permissionLabel).foregroundStyle(.secondary)
                    Button("Abrir Ajustes") { meeting.openPermissionSettings() }
                }
                Button("Abrir carpeta de reuniones") {
                    try? FileManager.default.createDirectory(at: MeetingStore.root, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(MeetingStore.root)
                }
            } header: { Text("Reuniones: permiso y archivos") }
        }
        .onAppear { meeting.permission = SystemAudioPermission.state }
    }

    private var permissionLabel: String {
        switch state.meeting.permission {
        case .granted: "Concedido"
        case .denied: "Denegado"
        case .unknown: "Se pide al grabar"
        }
    }
}
