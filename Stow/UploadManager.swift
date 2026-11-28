import Foundation
import StowCore
import UIKit
import UserNotifications

extension Notification.Name {
    /// Posted on the main queue whenever a note changes in the store.
    static let stowNotesChanged = Notification.Name("stowNotesChanged")
}

/// Sends recordings to Groq through a background `URLSession`.
///
/// This is the reason the app is native. iOS runs a background upload in its own
/// process: it continues after the phone is locked or Stow is suspended, waits for
/// signal when there is none, and relaunches Stow to deliver the answer. A web page
/// can do none of that.
///
/// What it does not survive is the user swiping Stow away in the app switcher. iOS
/// cancels the upload then. The note stays in history as failed, with its audio, and can
/// be sent again.
final class UploadManager: NSObject, URLSessionDataDelegate {

    static let shared = UploadManager()
    static let sessionIdentifier = "io.github.mds08011.stow.upload"

    let store = NoteStore(fileURL: Paths.history)

    /// Handed over by the app delegate when iOS relaunches Stow for finished uploads.
    private var backgroundCompletionHandler: (() -> Void)?
    private var handlingBackgroundEvents = false

    private static let pendingCopyKey = "pendingCopyNoteID"

    private var responseData: [Int: Data] = [:]
    private let dataLock = NSLock()

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: UploadManager.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        // Dictation is wanted now, not when iOS finds a convenient moment.
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        // How long one note may wait for signal before it is reported as failed.
        configuration.timeoutIntervalForResource = 12 * 60 * 60
        // The gap allowed between bytes. Groq sends nothing while it decodes, which for
        // a long note takes far longer than the default 60 seconds.
        configuration.timeoutIntervalForRequest = 10 * 60
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// Re-attaches the background session delegate without running an orphan sweep.
    func attachBackgroundSession() {
        _ = session
    }

    /// Called by `AppDelegate` when iOS relaunches Stow for finished background uploads.
    /// Does not sweep orphans yet: finished tasks may already be out of `getAllTasks`
    /// while their completion callbacks are still being delivered.
    func beginBackgroundEvents(completionHandler: @escaping () -> Void) {
        backgroundCompletionHandler = completionHandler
        handlingBackgroundEvents = true
        _ = session
    }

    /// Marks any `.uploading` note whose system task disappeared (e.g. after Stow was
    /// swiped away) as `.failed` while keeping its audio. Foreground-only so it cannot
    /// race with background completion delivery.
    func reconcileOrphans() {
        DispatchQueue.main.async {
            guard !self.handlingBackgroundEvents else { return }
            self.session.getAllTasks { [weak self] tasks in
                guard let self else { return }
                let live = Set(tasks.compactMap { $0.taskDescription })
                DispatchQueue.main.async {
                    guard !self.handlingBackgroundEvents else { return }
                    var changed = false
                    for note in self.store.all() where note.status == .uploading && !live.contains(note.id) {
                        self.store.update(id: note.id) {
                            $0.status = .failed
                            $0.errorMessage = "The upload was interrupted. The audio was kept."
                        }
                        changed = true
                    }
                    if changed {
                        self.announceChange()
                    }
                }
            }
        }
    }

    func consumePendingCopyNoteID() -> String? {
        let id = UserDefaults.standard.string(forKey: Self.pendingCopyKey)
        if id != nil {
            UserDefaults.standard.removeObject(forKey: Self.pendingCopyKey)
        }
        return id
    }

    func clearPendingCopyNoteID() {
        UserDefaults.standard.removeObject(forKey: Self.pendingCopyKey)
    }

    /// Queues one note's audio for transcription. Safe to call for any number of notes.
    func enqueue(noteID: String, apiKey: String, jargon: String) {
        guard let note = store.note(id: noteID), let fileName = note.audioFileName else { return }
        // Guard against double taps creating two tasks that overwrite the same outbox file,
        // and refuse to burn a rate-limit slot before Groq's Retry-After has elapsed.
        guard note.status != .uploading else { return }
        if let retryAt = note.retryAt, retryAt > Date() { return }
        let audioURL = Paths.recording(named: fileName)

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            fail(noteID, "The recording is no longer on this device.")
            return
        }
        guard !apiKey.isEmpty else {
            fail(noteID, "Add your Groq API key in Settings, then send this note again.")
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= Groq.maxUploadBytes else {
            fail(noteID, "Recording is too large for Groq to accept (limit about 25 MB). The audio was kept.")
            return
        }

        let boundary = MultipartFile.makeBoundary()
        let bodyURL = Paths.outbox.appendingPathComponent("\(noteID).multipart")
        do {
            try MultipartFile.write(
                to: bodyURL,
                boundary: boundary,
                fields: TranscriptionRequest.fields(jargon: jargon),
                fileURL: audioURL,
                fileName: fileName,
                mimeType: "audio/mp4"
            )
        } catch {
            fail(noteID, "Could not prepare the upload: \(error.localizedDescription)")
            return
        }

        let request = TranscriptionRequest.urlRequest(apiKey: apiKey, boundary: boundary)
        let task = session.uploadTask(with: request, fromFile: bodyURL)
        task.taskDescription = noteID
        store.update(id: noteID) {
            $0.status = .uploading
            $0.errorMessage = nil
            $0.retryAt = nil
        }
        task.resume()
        announceChange()
    }

    // MARK: URLSession delegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        dataLock.lock()
        responseData[dataTask.taskIdentifier, default: Data()].append(data)
        dataLock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        dataLock.lock()
        let body = responseData.removeValue(forKey: task.taskIdentifier) ?? Data()
        dataLock.unlock()

        guard let noteID = task.taskDescription else { return }
        try? FileManager.default.removeItem(at: Paths.outbox.appendingPathComponent("\(noteID).multipart"))

        if let error {
            fail(noteID, "Upload failed: \(error.localizedDescription) The audio was kept.")
            return
        }
        guard let http = task.response as? HTTPURLResponse else {
            fail(noteID, "Groq sent no response. The audio was kept.")
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: body, encoding: .utf8)
            let wait = ApiErrors.retryAfterSeconds(
                header: http.value(forHTTPHeaderField: "retry-after"),
                body: text,
                status: http.statusCode
            )
            store.update(id: noteID) {
                $0.status = .failed
                $0.errorMessage = ApiErrors.describe(status: http.statusCode, body: text)
                $0.retryAt = wait > 0 ? Date(timeIntervalSinceNow: TimeInterval(wait)) : nil
            }
            announceChange()
            return
        }
        guard let parsed = TranscriptionResponse.parse(body) else {
            fail(noteID, "Groq's answer could not be read. The audio was kept.")
            return
        }

        let saved = store.update(id: noteID) {
            $0.status = .done
            $0.rawText = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
            $0.avgLogprob = parsed.avgLogprob
            $0.maxNoSpeechProb = parsed.maxNoSpeechProb
            $0.maxCompressionRatio = parsed.maxCompressionRatio
            $0.errorMessage = nil
            $0.retryAt = nil
        }
        UserDefaults.standard.set(noteID, forKey: Self.pendingCopyKey)
        pruneAudioCache(keepFileName: saved?.audioFileName)
        announceChange()
        notifyReady(preview: parsed.text)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.handlingBackgroundEvents = false
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }

    // MARK: Helpers

    private func pruneAudioCache(keepFileName: String?) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: Paths.recordings,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let stored: [AudioRetention.StoredFile] = urls.compactMap { url in
            guard url.pathExtension.lowercased() == "m4a" else { return nil }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            return AudioRetention.StoredFile(name: url.lastPathComponent, modifiedAt: modified)
        }
        let doomed = AudioRetention.filesToDelete(
            files: stored,
            notes: store.all(),
            keepFileName: keepFileName
        )
        for name in doomed {
            try? fm.removeItem(at: Paths.recording(named: name))
        }
    }

    private func fail(_ noteID: String, _ message: String) {
        store.update(id: noteID) {
            $0.status = .failed
            $0.errorMessage = message
        }
        announceChange()
    }

    private func announceChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .stowNotesChanged, object: nil)
        }
    }

    /// A banner for when the transcription lands while Stow is not on screen. Skipped when
    /// Stow is already active so completed notes do not clutter Notification Center.
    private func notifyReady(preview: String) {
        DispatchQueue.main.async {
            guard UIApplication.shared.applicationState != .active else { return }
            let content = UNMutableNotificationContent()
            content.title = "Transcription ready"
            content.body = String(preview.prefix(120))
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }
}
