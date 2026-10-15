import Foundation
import LoroCore

/// Historial en disco (se borra solo a los 7 días) y estadísticas acumuladas que no se borran.
///
/// Vive en LoroKit, no en la app, porque hay DOS procesos escribiendo los mismos archivos:
/// Loro.app y el dictado embebido de Nido. Por eso toda escritura es lee-modifica-escribe
/// contra el disco (`record`, `clearHistory`): quien tenga una copia en memoria no puede
/// pisar lo que el otro proceso acaba de agregar.
public struct StoredDictation: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var date: Date
    public var text: String
    public var engine: EngineKind
    public var duration: TimeInterval
    public var source: String   // "Dictado" o nombre de archivo
    /// Etapas del texto, para auditar qué conviene dejar (opcional: dictados viejos no la tienen).
    public var stages: DictationStages?
    /// Nombre del WAV en `HistoryStore.audioDirectory`, si se guardó el audio.
    public var audioFile: String?

    public init(id: UUID = UUID(), date: Date, text: String, engine: EngineKind, duration: TimeInterval,
                source: String, stages: DictationStages? = nil, audioFile: String? = nil) {
        self.id = id; self.date = date; self.text = text; self.engine = engine
        self.duration = duration; self.source = source; self.stages = stages; self.audioFile = audioFile
    }

    public var audioURL: URL? { audioFile.map { HistoryStore.audioDirectory.appendingPathComponent($0) } }
    /// Dictado que no produjo texto pese a que había voz. Se guarda con su audio para poder
    /// oírlo y re-transcribirlo, en vez de perder la evidencia.
    public var isEmpty: Bool { text.isEmpty }
}

public struct DayStat: Codable, Equatable, Sendable {
    public var dictations = 0
    public var words = 0
    public var seconds: TimeInterval = 0

    public init(dictations: Int = 0, words: Int = 0, seconds: TimeInterval = 0) {
        self.dictations = dictations; self.words = words; self.seconds = seconds
    }
}

public struct LoroStats: Codable, Equatable, Sendable {
    public var firstUse: Date = Date()
    public var totalDictations = 0
    public var totalWords = 0
    public var totalSeconds: TimeInterval = 0
    public var byEngine: [String: Int] = [:]
    /// Por día (yyyy-MM-dd), se conservan 90 días para rachas y "mejor día".
    public var days: [String: DayStat] = [:]

    public init() {}

    public static let typingWordsPerMinute = 40.0

    /// Segundos que habría tomado teclear esas palabras, menos lo que tardó hablando.
    public static func savedSeconds(words: Int, spoken: TimeInterval) -> TimeInterval {
        max(0, Double(words) / typingWordsPerMinute * 60 - spoken)
    }

    public mutating func record(words: Int, seconds: TimeInterval, engine: EngineKind, date: Date) {
        totalDictations += 1
        totalWords += words
        totalSeconds += seconds
        byEngine[engine.rawValue, default: 0] += 1
        let key = Self.dayKey(date)
        var d = days[key] ?? DayStat()
        d.dictations += 1; d.words += words; d.seconds += seconds
        days[key] = d
        let cutoff = Self.dayKey(date.addingTimeInterval(-90 * 86_400))
        days = days.filter { $0.key >= cutoff }
    }

    public static func dayKey(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }

    public func week(from now: Date = Date()) -> DayStat {
        let cutoff = Self.dayKey(now.addingTimeInterval(-7 * 86_400))
        return days.filter { $0.key >= cutoff }.values.reduce(DayStat()) {
            DayStat(dictations: $0.dictations + $1.dictations, words: $0.words + $1.words, seconds: $0.seconds + $1.seconds)
        }
    }

    /// Días seguidos con al menos un dictado, contando hoy o ayer como inicio.
    public func streak(now: Date = Date()) -> Int {
        var day = now
        if days[Self.dayKey(day)] == nil { day = day.addingTimeInterval(-86_400) }
        var n = 0
        while days[Self.dayKey(day)] != nil { n += 1; day = day.addingTimeInterval(-86_400) }
        return n
    }

    public var favoriteEngine: EngineKind? {
        byEngine.max { $0.value < $1.value }.flatMap { EngineKind(rawValue: $0.key) }
    }
}

public enum HistoryStore {
    public static let retentionDays = 7
    public static var historyURL: URL { ModelStore.root.appendingPathComponent("history.json") }
    public static var statsURL: URL { ModelStore.root.appendingPathComponent("stats.json") }
    public static var audioDirectory: URL { ModelStore.root.appendingPathComponent("audio", isDirectory: true) }

    /// Bajo este nivel de audio se da por hecho que no se habló (se apretó el atajo y nada más).
    public static let silenceRMS: Float = 0.005

    /// Loro y Nido escriben estos mismos archivos desde procesos distintos. `NSLock` solo
    /// serializa los hilos de UN proceso; el `flock` sobre `history.lock` serializa entre
    /// procesos. Sin él, una escritura de Nido podía pisar la de Loro, y su `pruneAudio`
    /// borrar un WAV recién guardado que todavía no estaba en el historial.
    private static let lock = NSLock()
    static var lockURL: URL { ModelStore.root.appendingPathComponent("history.lock") }

    private static func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: ModelStore.root, withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        return body()
    }

    // MARK: - Registrar un dictado

    /// Guarda un dictado: WAV (si corresponde), fila en el historial y estadísticas.
    /// Es el ÚNICO camino de escritura que deben usar las apps — lee del disco antes de
    /// escribir, así Loro y Nido no se pisan.
    ///
    /// Un dictado sin texto igual se guarda si HABLASTE y aun así no salió nada: esa fila es
    /// la evidencia para oírlo y re-transcribirlo. Si simplemente apretaste y no hablaste
    /// (silencio), no deja rastro: no hay nada que auditar y ensuciaría el historial.
    @discardableResult
    public static func record(_ r: DictationResult, settings: LoroSettings) -> StoredDictation? {
        // Voz real en los dictados del 8-sep: RMS 0.007–0.026. Un dictado en silencio marcó
        // 0.003. El corte va al medio, más cerca del silencio.
        let spoke = (r.clip?.rms ?? 0) >= silenceRMS
        guard !r.text.isEmpty || spoke else { return nil }
        let keepsAudio = settings.keepHistory && settings.keepAudio && r.source == "Dictado"
        // El WAV se escribe DENTRO del candado: si no, otra escritura podía borrarlo por huérfano.
        return locked { () -> StoredDictation? in
            let audio = keepsAudio ? r.clip.flatMap { saveAudio($0, id: r.id) } : nil
            guard !r.text.isEmpty || audio != nil else { return nil }

            if !r.text.isEmpty {
                var s = loadStatsLocked()
                s.record(words: r.text.wordCount, seconds: r.audioDuration, engine: r.engine, date: r.started)
                writeStats(s)
            }

            guard settings.keepHistory else { return nil }
            let item = StoredDictation(id: r.id, date: r.started, text: r.text, engine: r.engine,
                                       duration: r.audioDuration, source: r.source, stages: r.stages, audioFile: audio)
            var items = loadHistoryLocked()
            items.insert(item, at: 0)
            writeHistory(items)
            return item
        }
    }

    /// Reemplaza el texto de un dictado ya guardado (re-transcribir con otro motor).
    /// No toca las estadísticas: es el mismo dictado, no uno nuevo.
    public static func updateText(id: UUID, text: String, engine: EngineKind, stages: DictationStages?) {
        locked {
            var items = loadHistoryLocked()
            guard let i = items.firstIndex(where: { $0.id == id }) else { return }
            items[i].text = text
            items[i].engine = engine
            if let stages { items[i].stages = stages }
            writeHistory(items)
        }
    }

    /// Vacía el historial (y con él los WAV que ya no referencia nadie).
    public static func clearHistory() {
        locked { writeHistory([]) }
    }

    /// Borra un dictado puntual del historial.
    public static func delete(id: UUID) {
        locked { writeHistory(loadHistoryLocked().filter { $0.id != id }) }
    }

    // MARK: - Audio

    /// Escribe el audio de un dictado y devuelve el nombre de archivo (nil si falló).
    public static func saveAudio(_ clip: AudioClip, id: UUID) -> String? {
        let name = "\(id.uuidString).wav"
        do {
            try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
            try clip.write(to: audioDirectory.appendingPathComponent(name))
            return name
        } catch { return nil }
    }

    /// Borra los WAV que ya no tienen dictado en el historial (por retención o por "Vaciar").
    public static func pruneAudio(keeping items: [StoredDictation]) {
        let keep = Set(items.compactMap(\.audioFile))
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: audioDirectory.path) else { return }
        for f in files where !keep.contains(f) {
            try? FileManager.default.removeItem(at: audioDirectory.appendingPathComponent(f))
        }
    }

    // MARK: - Lectura

    public static func loadHistory() -> [StoredDictation] {
        locked { loadHistoryLocked() }
    }

    public static func loadStats() -> LoroStats {
        locked { loadStatsLocked() }
    }

    public static func prune(_ items: [StoredDictation]) -> [StoredDictation] {
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        return items.filter { $0.date >= cutoff }
    }

    // MARK: - Interno (asume `locked` tomado)

    private static func loadHistoryLocked() -> [StoredDictation] {
        guard let data = try? Data(contentsOf: historyURL),
              let items = try? decoder.decode([StoredDictation].self, from: data) else { return [] }
        return prune(items)
    }

    private static func loadStatsLocked() -> LoroStats {
        guard let data = try? Data(contentsOf: statsURL), let s = try? decoder.decode(LoroStats.self, from: data) else { return LoroStats() }
        return s
    }

    private static func writeHistory(_ items: [StoredDictation]) {
        try? FileManager.default.createDirectory(at: ModelStore.root, withIntermediateDirectories: true)
        let kept = prune(items)
        try? encoder.encode(kept).write(to: historyURL, options: .atomic)
        pruneAudio(keeping: kept)
    }

    private static func writeStats(_ s: LoroStats) {
        try? FileManager.default.createDirectory(at: ModelStore.root, withIntermediateDirectories: true)
        try? encoder.encode(s).write(to: statsURL, options: .atomic)
    }

    private static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }
    private static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

extension String {
    public var wordCount: Int { split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count }
}
