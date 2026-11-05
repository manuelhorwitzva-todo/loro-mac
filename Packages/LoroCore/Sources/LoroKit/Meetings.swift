import Foundation
import LoroCore

/// Preferencias de la grabación de reuniones. Archivo aparte de `settings.json` a propósito:
/// `LoroSettings` se decodifica entero y un campo nuevo haría que una versión vieja (o Nido)
/// no lo pudiera leer y volviera a los valores de fábrica.
public struct MeetingSettings: Codable, Equatable, Sendable {
    /// Transcribir en este Mac al terminar (respaldo; el destino puede transcribir por su cuenta).
    public var transcribeLocally = true
    /// Solo el audio de navegadores y apps de videollamada. false = todo el audio del Mac.
    public var onlyMeetingApps = true
    /// Comando que se corre al terminar cada reunión (vacío = nada). Recibe las rutas en
    /// variables de entorno (ver `MeetingStore.hookEnvironment`). Así un destino (subir a otro
    /// sistema, mover a Drive) se conecta sin que Loro sepa nada de él.
    public var onFinishCommand = ""
    /// Días que se guardan las reuniones en este Mac. 0 = para siempre.
    public var keepDays = 30

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MeetingSettings()
        transcribeLocally = try c.decodeIfPresent(Bool.self, forKey: .transcribeLocally) ?? d.transcribeLocally
        onlyMeetingApps = try c.decodeIfPresent(Bool.self, forKey: .onlyMeetingApps) ?? d.onlyMeetingApps
        onFinishCommand = try c.decodeIfPresent(String.self, forKey: .onFinishCommand) ?? d.onFinishCommand
        keepDays = try c.decodeIfPresent(Int.self, forKey: .keepDays) ?? d.keepDays
    }

    public static var fileURL: URL { ModelStore.root.appendingPathComponent("meetings.json") }

    public static func load() -> MeetingSettings {
        guard let data = try? Data(contentsOf: fileURL), let s = try? JSONDecoder().decode(MeetingSettings.self, from: data) else {
            return MeetingSettings()
        }
        return s
    }

    public func save() {
        try? FileManager.default.createDirectory(at: ModelStore.root, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: Self.fileURL, options: .atomic)
    }
}

/// Lo que queda de una reunión en disco, leído desde su carpeta.
public struct StoredMeeting: Identifiable, Codable, Equatable, Sendable {
    public var id: String { folderName }
    public var folderName: String
    public var title: String
    public var started: Date
    public var duration: TimeInterval
    public var micSignalSeconds: Double
    public var systemSignalSeconds: Double
    /// nil mientras se transcribe o si no se transcribió.
    public var transcriptFile: String?
    public var engine: String?
    public var hookStatus: String?

    public init(folderName: String, title: String, started: Date, duration: TimeInterval,
                micSignalSeconds: Double, systemSignalSeconds: Double) {
        self.folderName = folderName; self.title = title; self.started = started; self.duration = duration
        self.micSignalSeconds = micSignalSeconds; self.systemSignalSeconds = systemSignalSeconds
    }

    public var folder: URL { MeetingStore.root.appendingPathComponent(folderName, isDirectory: true) }
    public var mixURL: URL { folder.appendingPathComponent("reunion.m4a") }
    public var transcriptURL: URL? { transcriptFile.map { folder.appendingPathComponent($0) } }
}

/// Carpeta de reuniones: ~/Library/Application Support/Loro/Reuniones/<fecha hora>/
///   tu.m4a, otros.m4a, reunion.m4a, transcripcion.md, reunion.json
public enum MeetingStore {
    public static var root: URL { ModelStore.root.appendingPathComponent("Reuniones", isDirectory: true) }

    public static func newFolder(started: Date = Date()) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return root.appendingPathComponent(f.string(from: started), isDirectory: true)
    }

    public static func save(_ m: StoredMeeting) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        try? enc.encode(m).write(to: m.folder.appendingPathComponent("reunion.json"), options: .atomic)
    }

    public static func load() -> [StoredMeeting] {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("reunion.json")) else { return nil }
            return try? dec.decode(StoredMeeting.self, from: data)
        }.sorted { $0.started > $1.started }
    }

    /// Borra las reuniones más viejas que `days` días (0 = nunca).
    public static func prune(days: Int) {
        guard days > 0 else { return }
        let limit = Date().addingTimeInterval(-Double(days) * 86_400)
        for m in load() where m.started < limit { try? FileManager.default.removeItem(at: m.folder) }
    }

    /// Variables que recibe el comando de "al terminar".
    public static func hookEnvironment(_ m: StoredMeeting) -> [String: String] {
        let iso = ISO8601DateFormatter()
        var env = [
            "LORO_MEETING_DIR": m.folder.path,
            "LORO_MEETING_MIX": m.mixURL.path,
            "LORO_MEETING_MIC": m.folder.appendingPathComponent("tu.m4a").path,
            "LORO_MEETING_OTHERS": m.folder.appendingPathComponent("otros.m4a").path,
            "LORO_MEETING_START": iso.string(from: m.started),
            "LORO_MEETING_END": iso.string(from: m.started.addingTimeInterval(m.duration)),
            "LORO_MEETING_SECONDS": String(Int(m.duration.rounded())),
            "LORO_MEETING_JSON": m.folder.appendingPathComponent("reunion.json").path,
        ]
        if let t = m.transcriptURL { env["LORO_MEETING_TRANSCRIPT"] = t.path }
        return env
    }

    /// Corre el comando con zsh, con las variables de la reunión. Devuelve una línea de estado.
    public static func runHook(_ command: String, for m: StoredMeeting) async -> String {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", command]
            p.environment = ProcessInfo.processInfo.environment.merging(hookEnvironment(m)) { _, new in new }
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do { try p.run() } catch { cont.resume(returning: "no se pudo correr: \(error.localizedDescription)"); return }
            // Se lee la salida mientras corre: si se esperara al final, un comando que escribe
            // mucho llenaría el pipe y quedaría trabado para siempre.
            DispatchQueue.global().async {
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                p.waitUntilExit()
                let last = out.split(separator: "\n").last.map(String.init) ?? ""
                let tail = last.isEmpty ? "" : ": \(last.prefix(200))"
                cont.resume(returning: p.terminationStatus == 0 ? "ok\(tail)" : "falló (\(p.terminationStatus))\(tail)")
            }
        }
    }
}
