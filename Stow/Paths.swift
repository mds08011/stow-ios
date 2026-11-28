import Foundation

/// Where Stow keeps its files. Everything is under Application Support, which iOS never
/// clears on its own. Unsent audio must not live in Caches or tmp, both of which the
/// system may empty when storage runs low.
enum Paths {

    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent("Stow", isDirectory: true))
    }

    static var recordings: URL {
        ensure(root.appendingPathComponent("recordings", isDirectory: true), excludeFromBackup: true)
    }

    /// Multipart bodies waiting on the background uploader. Deleted when a task finishes.
    static var outbox: URL {
        ensure(root.appendingPathComponent("outbox", isDirectory: true), excludeFromBackup: true)
    }

    static var history: URL {
        root.appendingPathComponent("history.json")
    }

    static func recording(named fileName: String) -> URL {
        recordings.appendingPathComponent(fileName)
    }

    private static func ensure(_ url: URL, excludeFromBackup: Bool = false) -> URL {
        var target = url
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        if excludeFromBackup {
            // Audio and temporary upload bodies are large, short-lived, and may hold other
            // people's voices, so keep them out of iCloud Backup (matching Android's rules).
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? target.setResourceValues(values)
        }
        return target
    }
}
