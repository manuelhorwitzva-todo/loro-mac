import AppKit
import Foundation
import LoroCore
import LoroKit
import Observation
import os
import SwiftUI

let meetingUILog = Logger(subsystem: "cl.manulit0.loro", category: "meeting-ui")

/// Grabar reunión: estado para la UI, el indicador rojo y lo que pasa al terminar
/// (exportar, transcribir en este Mac, correr el comando de "al terminar").
@MainActor
@Observable
final class MeetingController {
    /// Solo la grabación. Lo que viene después (transcribir, enviar) va aparte, en una cola,
    /// para poder empezar la próxima reunión mientras la anterior todavía se transcribe.
    enum Phase: Equatable {
        case idle
        case recording(since: Date)
        case saving
        case error(String)
    }

    var phase: Phase = .idle
    /// Avance de la transcripción local en curso (nil = no hay ninguna).
    var transcribing: Double?
    var micLevel: Float = 0
    var systemLevel: Float = 0
    var meetings: [StoredMeeting] = MeetingStore.load()
    var settings = MeetingSettings.load() { didSet { settings.save() } }
    var permission: SystemAudioPermission.State = SystemAudioPermission.state
    /// La reunión lleva rato grabando y la pista de los demás sigue muda: o no hay nadie
    /// hablando todavía, o falta el permiso de audio del sistema (que no da error, da silencio).
    var othersSilentWarning = false

    private var recorder: MeetingRecorder?
    private var meter: Task<Void, Never>?
    private var postQueue: Task<Void, Never>?
    private let indicator = MeetingIndicator()
    private weak var session: DictationSession?

    var isRecording: Bool { if case .recording = phase { true } else { false } }
    var canStart: Bool { phase == .idle || isError }
    private var isError: Bool { if case .error = phase { true } else { false } }

    init(session: DictationSession) {
        self.session = session
        MeetingStore.prune(days: settings.keepDays)
        // Para automatizar (Atajos, un script, una futura detección de llamadas) sin abrir el menú.
        DistributedNotificationCenter.default().addObserver(forName: .init("cl.manulit0.loro.meeting.toggle"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.toggle() }
        }
        Task { await recoverInterrupted() }
    }

    func toggle() { isRecording ? stop() : start() }

    func start() {
        guard canStart else { return }
        phase = .saving   // bloquea un doble clic mientras se pide el permiso
        Task {
            if SystemAudioPermission.state != .granted { _ = await SystemAudioPermission.request() }
            permission = SystemAudioPermission.state
            meetingUILog.notice("permiso de audio del sistema: \(String(describing: self.permission), privacy: .public)")
            let folder = MeetingStore.newFolder()
            do {
                let rec = try MeetingRecorder(folder: folder)
                try rec.start(bundleIDs: settings.onlyMeetingApps ? SystemAudioCapture.meetingBundleIDs : [])
                recorder = rec
                let since = Date()
                phase = .recording(since: since)
                MediaPause.meetingInProgress = true
                othersSilentWarning = false
                indicator.show(controller: self)
                if AppState.shared.settings.playSounds { NSSound(named: "Pop")?.play() }
                startMeter(since: since)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                phase = .error(error.localizedDescription)
                meetingUILog.error("no se pudo empezar: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func startMeter(since: Date) {
        meter?.cancel()
        meter = Task { [weak self] in
            while let self, let rec = recorder, !Task.isCancelled {
                let l = rec.levels
                micLevel = l.mic; systemLevel = l.system
                // A los 45 s sin nada en la pista de los demás, se avisa.
                othersSilentWarning = Date().timeIntervalSince(since) > 45 && rec.signalSeconds.system < 1
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    func stop() {
        guard isRecording, let rec = recorder else { return }
        meter?.cancel()
        recorder = nil
        phase = .saving
        MediaPause.meetingInProgress = false
        indicator.hide()
        if AppState.shared.settings.playSounds { NSSound(named: "Tink")?.play() }
        Task {
            do {
                let r = try await rec.stop()
                let m = StoredMeeting(folderName: r.folder.lastPathComponent, title: Self.title(for: r.started), started: r.started,
                                      duration: r.duration, micSignalSeconds: r.micSignalSeconds, systemSignalSeconds: r.systemSignalSeconds)
                MeetingStore.save(m)
                meetings = MeetingStore.load()
                phase = .idle
                AppState.shared.hud.flash("Reunión guardada")
                enqueuePostProcessing(m)
            } catch {
                phase = .error("No se pudo guardar: \(error.localizedDescription)")
            }
        }
    }

    /// Transcribir y enviar, de a una reunión a la vez y en orden.
    private func enqueuePostProcessing(_ meeting: StoredMeeting) {
        let previous = postQueue
        postQueue = Task { [weak self] in
            await previous?.value
            await self?.postProcess(meeting)
        }
    }

    private func postProcess(_ meeting: StoredMeeting) async {
        var m = meeting
        if settings.transcribeLocally, m.transcriptFile == nil { m = await transcribe(m) }
        Self.removeRaw(in: m.folder)
        if !settings.onFinishCommand.trimmingCharacters(in: .whitespaces).isEmpty, m.hookStatus == nil || m.hookStatus == "enviando…" {
            m.hookStatus = "enviando…"
            MeetingStore.save(m); meetings = MeetingStore.load()
            m.hookStatus = await MeetingStore.runHook(settings.onFinishCommand, for: m)
            meetingUILog.info("comando al terminar: \(m.hookStatus ?? "", privacy: .public)")
            MeetingStore.save(m)
        }
        meetings = MeetingStore.load()
    }

    private func transcribe(_ meeting: StoredMeeting) async -> StoredMeeting {
        guard let session else { return meeting }
        var m = meeting
        transcribing = 0
        defer { transcribing = nil }
        let engine = AppState.shared.settings.engine
        do {
            let turns = try await MeetingTranscriber().transcribe(
                mic: m.folder.appendingPathComponent("tu.caf"), system: m.folder.appendingPathComponent("otros.caf"),
                transcribe: { clip in await session.transcribeSegment(clip) },
                progress: { p in Task { @MainActor [weak self] in if self?.transcribing != nil { self?.transcribing = p } } })
            let me = NSFullUserName().split(separator: " ").first.map(String.init) ?? "Tú"
            let md = MeetingTranscriber.markdown(turns, title: m.title, started: m.started, duration: m.duration,
                                                 meName: me, engine: engine.shortName)
            try md.write(to: m.folder.appendingPathComponent("transcripcion.md"), atomically: true, encoding: .utf8)
            m.transcriptFile = "transcripcion.md"
            m.engine = engine.shortName
            MeetingStore.save(m)
        } catch {
            meetingUILog.error("transcripción falló: \(error.localizedDescription, privacy: .public)")
        }
        return m
    }

    /// Al abrir Loro: reuniones que quedaron a medias porque Loro se cerró (o el Mac se apagó).
    /// - Grabando: hay CAF pero no `reunion.json` → se exporta lo que alcanzó a grabarse.
    /// - Transcribiendo o enviando: hay `reunion.json` y todavía CAF → se retoma.
    private func recoverInterrupted() async {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: MeetingStore.root, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs.sorted(by: { $0.path < $1.path }) {
            let hasRaw = fm.fileExists(atPath: dir.appendingPathComponent("tu.caf").path)
                || fm.fileExists(atPath: dir.appendingPathComponent("otros.caf").path)
            guard hasRaw, recorder?.folder != dir else { continue }
            if let m = meetings.first(where: { $0.folderName == dir.lastPathComponent }) {
                enqueuePostProcessing(m)
                continue
            }
            do {
                let r = try await Task.detached { try MeetingRecorder.recover(folder: dir) }.value
                let m = StoredMeeting(folderName: dir.lastPathComponent, title: Self.title(for: r.started) + " (recuperada)",
                                      started: r.started, duration: r.duration,
                                      micSignalSeconds: r.micSignalSeconds, systemSignalSeconds: r.systemSignalSeconds)
                MeetingStore.save(m)
                meetings = MeetingStore.load()
                meetingUILog.notice("reunión recuperada: \(dir.lastPathComponent, privacy: .public), \(r.duration, format: .fixed(precision: 0)) s")
                enqueuePostProcessing(m)
            } catch {
                meetingUILog.error("no se pudo recuperar \(dir.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Los CAF crudos (~350 MB por hora y pista) solo sirven hasta tener los m4a y la transcripción.
    private static func removeRaw(in folder: URL) {
        for name in ["tu.caf", "otros.caf"] { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
    }

    static func title(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_CL")
        f.dateFormat = "'Reunión del' d 'de' MMMM, HH:mm"
        return f.string(from: date)
    }

    func dismissError() { if isError { phase = .idle } }

    func reveal(_ m: StoredMeeting) { NSWorkspace.shared.activateFileViewerSelecting([m.mixURL]) }

    func openTranscript(_ m: StoredMeeting) {
        guard let url = m.transcriptURL else { return }
        NSWorkspace.shared.open(url)
    }

    func delete(_ m: StoredMeeting) {
        try? FileManager.default.removeItem(at: m.folder)
        meetings = MeetingStore.load()
    }

    func openPermissionSettings() { NSWorkspace.shared.open(SystemAudioPermission.openSettings()) }
}

/// Indicador rojo fijo mientras se graba una reunión, arriba a la derecha y sobre todas las
/// ventanas. No se puede esconder sin parar: grabar desde el Mac no le avisa a nadie en la
/// llamada, así que al menos quien graba no se puede olvidar de que está grabando.
@MainActor
final class MeetingIndicator {
    private var panel: NSPanel?

    func show(controller: MeetingController) {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 44),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.isMovableByWindowBackground = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.hidesOnDeactivate = false
            let host = NSHostingView(rootView: MeetingIndicatorView().environment(controller))
            host.sizingOptions = [.preferredContentSize]
            p.contentView = host
            panel = p
        }
        if let screen = NSScreen.main, let panel {
            // El tamaño real se conoce recién después de un layout: si se ubica con el tamaño
            // inicial, la pastilla crece hacia la derecha y queda fuera de la pantalla.
            panel.contentView?.layoutSubtreeIfNeeded()
            var size = panel.contentView?.fittingSize ?? .zero
            if size.width < 100 || size.height < 20 { size = NSSize(width: 340, height: 52) }
            panel.setContentSize(size)
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.maxX - size.width - 16, y: f.maxY - size.height - 12))
        }
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }
}

struct MeetingIndicatorView: View {
    @Environment(MeetingController.self) private var meeting

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(.red).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("Grabando reunión").font(.callout.weight(.semibold))
                    if case .recording(let since) = meeting.phase {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(MeetingTranscriber.clock(ctx.date.timeIntervalSince(since))).font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if meeting.othersSilentWarning {
                    Text("No llega audio de la reunión").font(.caption2).foregroundStyle(.orange)
                } else {
                    HStack(spacing: 6) {
                        LevelBar(label: "Tú", level: meeting.micLevel)
                        LevelBar(label: "Otros", level: meeting.systemLevel)
                    }
                }
            }
            Button { meeting.stop() } label: {
                Image(systemName: "stop.fill").font(.callout).foregroundStyle(.white)
                    .frame(width: 26, height: 26).background(Circle().fill(.red))
            }
            .buttonStyle(.plain).help("Terminar y guardar")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.red.opacity(0.5), lineWidth: 1))
        .fixedSize()
    }
}

struct LevelBar: View {
    let label: String
    let level: Float
    var body: some View {
        HStack(spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.green).frame(width: g.size.width * CGFloat(min(1, sqrt(level) * 3)))
                }
            }
            .frame(width: 44, height: 4)
        }
    }
}
