import Foundation
import StowCore
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
    var backgroundCompletionHandler: (() -> Void)?

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

    /// Reconnects to uploads that were running when Stow was last suspended or killed.
    /// Call once at launch.
    func start() {
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            let live = Set(tasks.compactMap { $0.taskDescription })
            // A note marked uploading with no task behind it lost its upload, for
            // instance because Stow was swiped away. Say so, and keep the audio.
            for note in self.store.all() where note.status == .uploading && !live.contains(note.id) {
                self.store.update(id: note.id) {
                    $0.status = .failed
                    $0.errorMessage = "The upload was interrupted. The audio was kept."
                }
            }
            self.announceChange()
        }
    }

    /// Queues one note's audio for transcription. Safe to call for any number of notes.
    func enqueue(noteID: String, apiKey: String, jargon: String) {
        guard let note = store.note(id: noteID), let fileName = note.audioFileName else { return }
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

        store.update(id: noteID) {
            $0.status = .done
            $0.rawText = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
            $0.avgLogprob = parsed.avgLogprob
            $0.maxNoSpeechProb = parsed.maxNoSpeechProb
            $0.maxCompressionRatio = parsed.maxCompressionRatio
            $0.errorMessage = nil
            $0.retryAt = nil
        }
        announceChange()
        notifyReady(preview: parsed.text)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }

    // MARK: Helpers

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

    /// A banner for when the transcription lands while Stow is not on screen. iOS shows
    /// nothing for a foreground app unless asked to, which is the behaviour wanted here.
    private func notifyReady(preview: String) {
        let content = UNMutableNotificationContent()
        content.title = "Transcription ready"
        content.body = String(preview.prefix(120))
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
