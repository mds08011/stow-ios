import Foundation

/// One dictated note, from the moment recording stops.
///
/// The entry is created before the upload starts, in the `waiting` state, so any number
/// of recordings can queue in a dead zone and each one keeps a pointer to its audio.
public struct Note: Codable, Identifiable, Equatable {

    public enum Status: String, Codable {
        /// Recorded, not yet transcribed. The audio is on disk.
        case waiting
        /// Handed to the system's background uploader.
        case uploading
        case done
        /// The upload or transcription failed. The audio is still on disk.
        case failed
    }

    public var id: String
    public var createdAt: Date
    public var durationSeconds: Int
    public var status: Status
    public var rawText: String?
    public var polishedText: String?
    /// File name inside the recordings folder, never a full path: the app container's
    /// path changes between installs.
    public var audioFileName: String?
    /// The microphone iOS actually routed to, read back after recording started.
    public var micLabel: String?
    public var errorMessage: String?
    /// Earliest time a retry could succeed, after a rate limit.
    public var retryAt: Date?
    public var avgLogprob: Double?
    public var maxNoSpeechProb: Double?
    public var maxCompressionRatio: Double?

    public init(
        id: String = UUID().uuidString,
        createdAt: Date = Date(),
        durationSeconds: Int,
        status: Status = .waiting,
        audioFileName: String?,
        micLabel: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.status = status
        self.audioFileName = audioFileName
        self.micLabel = micLabel
    }

    /// Polished when there is one, otherwise raw.
    public var displayText: String {
        if let polished = polishedText, !polished.isEmpty { return polished }
        return rawText ?? ""
    }

    public var qualityWarning: String? {
        QualityCheck.warning(
            avgLogprob: avgLogprob,
            maxNoSpeechProb: maxNoSpeechProb,
            maxCompressionRatio: maxCompressionRatio
        )
    }
}

/// History as one JSON file, newest first. Same idea as Android's `stow_history.json`.
///
/// Every write goes to a temporary file and is then moved into place, so a kill
/// mid-write leaves the previous file intact. A file that fails to parse is set aside,
/// never overwritten.
public final class NoteStore {

    private let fileURL: URL
    private let lock = NSLock()
    private var cache: [Note]?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func all() -> [Note] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    public func note(id: String) -> Note? {
        all().first { $0.id == id }
    }

    public func add(_ note: Note) {
        mutate { $0.insert(note, at: 0) }
    }

    /// Applies `change` to the note with this id, if it still exists.
    @discardableResult
    public func update(id: String, _ change: (inout Note) -> Void) -> Note? {
        var result: Note?
        mutate { notes in
            guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
            change(&notes[index])
            result = notes[index]
        }
        return result
    }

    public func delete(id: String) {
        mutate { $0.removeAll { $0.id == id } }
    }

    /// Audio seconds transcribed on the given day, for the free-tier meter.
    public func secondsTranscribed(on day: Date, calendar: Calendar = .current) -> Int {
        all()
            .filter { $0.status == .done && calendar.isDate($0.createdAt, inSameDayAs: day) }
            .reduce(0) { $0 + $1.durationSeconds }
    }

    private func mutate(_ change: (inout [Note]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var notes = loadLocked()
        change(&notes)
        cache = notes
        saveLocked(notes)
    }

    private func loadLocked() -> [Note] {
        if let cache { return cache }
        var notes: [Note] = []
        if let data = try? Data(contentsOf: fileURL) {
            do {
                notes = try Self.decoder.decode([Note].self, from: data)
            } catch {
                // Keep the unreadable file for a human to look at. Starting empty and
                // saving over it would turn one bad write into a lost history.
                let aside = fileURL.deletingLastPathComponent()
                    .appendingPathComponent("history-unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: fileURL, to: aside)
            }
        }
        cache = notes
        return notes
    }

    private func saveLocked(_ notes: [Note]) {
        do {
            let data = try Self.encoder.encode(notes)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // The in-memory copy is still correct for this run. Nothing else to do here.
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
