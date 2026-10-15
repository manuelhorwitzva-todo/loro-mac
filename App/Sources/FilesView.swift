import LoroCore
import LoroKit
import SwiftUI
import UniformTypeIdentifiers

/// Ventana para soltar archivos de audio (o video) y obtener el texto.
struct FilesView: View {
    @Environment(AppState.self) private var state
    @State private var dropping = false
    @State private var selected: UUID?

    static let types: [UTType] = [.audio, .movie, .mpeg4Movie, .mpeg4Audio, .wav, .aiff, .mp3, .quickTimeMovie]

    var body: some View {
        VStack(spacing: 0) {
            dropZone
            Divider()
            HStack(spacing: 0) {
                jobList.frame(width: 280)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Archivos")
        .onDrop(of: Self.types, isTargeted: $dropping) { providers in handle(providers) }
    }

    private var dropZone: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform.badge.plus").font(.system(size: 26)).foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 2) {
                Text("Suelta audio o video aquí").font(.headline)
                Text("wav · m4a · mp3 · aiff · mp4 · mov").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Elegir archivos…") { pick() }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(dropping ? Color.teal.opacity(0.12) : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(dropping ? .teal : .secondary.opacity(0.35))
                .padding(10)
        )
    }

    private var jobList: some View {
        List(selection: $selected) {
            ForEach(state.fileJobs) { job in
                HStack(spacing: 8) {
                    jobIcon(job.state)
                    Text(job.url.lastPathComponent).lineLimit(1)
                    Spacer()
                }
                .tag(job.id)
            }
        }
        .listStyle(.inset)
        .frame(maxHeight: .infinity)
        .overlay {
            if state.fileJobs.isEmpty {
                Text("Sin archivos").foregroundStyle(.secondary)
            }
        }
        .toolbar {
            ToolbarItem { Button("Limpiar") { state.clearFinishedJobs(); selected = nil }.disabled(state.fileJobs.isEmpty) }
        }
    }

    @ViewBuilder
    private func jobIcon(_ s: AppState.FileJob.State) -> some View {
        switch s {
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var detail: some View {
        let job = selected.flatMap { id in state.fileJobs.first { $0.id == id } }
        switch job?.state {
        case .done(let text):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(job!.url.lastPathComponent).font(.headline).lineLimit(1)
                    Spacer()
                    Button("Copiar") { Paster.copyOnly(text) }
                    Button("Guardar .txt…") { save(text, next: job!.url) }
                }
                TextEditor(text: .constant(text)).font(.body).scrollContentBackground(.hidden)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding()
        case .failed(let err):
            ContentUnavailableView("No se pudo transcribir", systemImage: "xmark.octagon", description: Text(err))
        case .running:
            VStack(spacing: 10) { ProgressView(); Text(state.status.label).foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            ContentUnavailableView("Elige un archivo", systemImage: "text.quote", description: Text("El texto aparece aquí cuando termina."))
        }
    }

    private func handle(_ providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { urls.append(url) }
                else if let url = item as? URL { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { state.transcribeFiles(urls) }
        return !providers.isEmpty
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.types
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { state.transcribeFiles(panel.urls) }
    }

    private func save(_ text: String, next url: URL) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + ".txt"
        panel.directoryURL = url.deletingLastPathComponent()
        if panel.runModal() == .OK, let out = panel.url { try? text.write(to: out, atomically: true, encoding: .utf8) }
    }
}
