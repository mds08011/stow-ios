import Foundation
import StowCore
import SwiftUI
import UIKit
import UserNotifications

/// The one object the screens observe. Owns the recorder, mirrors the note store, and
/// holds the two settings.
@MainActor
final class AppModel: ObservableObject {

    @Published private(set) var notes: [Note] = []
    @Published var banner: String?
    @Published var jargon: String {
        didSet { UserDefaults.standard.set(jargon, forKey: Self.jargonKey) }
    }
    @Published private(set) var hasKey: Bool

    let recorder = Recorder()
    private let uploads = UploadManager.shared
    private var observer: NSObjectProtocol?

    private static let jargonKey = "jargon"

    init() {
        jargon = UserDefaults.standard.string(forKey: Self.jargonKey) ?? ""
        hasKey = !KeychainStore.readKey().isEmpty
        notes = uploads.store.all()

        observer = NotificationCenter.default.addObserver(
            forName: .stowNotesChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        uploads.start()
    }

    func reload() {
        notes = uploads.store.all()
    }

    /// The newest note, which is what the main screen shows under the record button.
    var latest: Note? { notes.first }

    var secondsToday: Int {
        uploads.store.secondsTranscribed(on: Date())
    }

    // MARK: Recording

    func toggleRecording() {
        if recorder.state == .idle {
            startRecording()
        } else {
            stopRecording()
        }
    }

    private func startRecording() {
        banner = nil
        guard hasKey else {
            banner = "Add your Groq API key in Settings before recording."
            return
        }
        // Asked here, at the first recording, so the "Transcription ready" banner can
        // appear when the answer lands on a locked phone. Recording works without it.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        recorder.start { [weak self] problem in
            guard let self else { return }
            if let problem {
                self.banner = problem
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            } else {
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            }
        }
    }

    private func stopRecording() {
        guard let finished = recorder.stop() else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        guard finished.durationSeconds > 0 else {
            try? FileManager.default.removeItem(at: Paths.recording(named: finished.fileName))
            banner = "Nothing was captured."
            return
        }

        // Saved before the upload starts. From here the note exists whether or not the
        // upload ever succeeds, and it keeps its own pointer to the audio.
        let note = Note(
            durationSeconds: finished.durationSeconds,
            audioFileName: finished.fileName,
            micLabel: finished.micLabel
        )
        uploads.store.add(note)
        reload()
        send(note.id)
    }

    // MARK: Notes

    func send(_ noteID: String) {
        uploads.enqueue(noteID: noteID, apiKey: KeychainStore.readKey(), jargon: jargon)
    }

    /// Sends every note that still has audio and no transcript.
    func sendAllWaiting() {
        for note in notes where note.status == .failed || note.status == .waiting {
            send(note.id)
        }
    }

    var waitingCount: Int {
        notes.filter { $0.status == .failed || $0.status == .waiting }.count
    }

    func delete(_ note: Note) {
        if let fileName = note.audioFileName {
            try? FileManager.default.removeItem(at: Paths.recording(named: fileName))
        }
        uploads.store.delete(id: note.id)
        reload()
    }

    func copy(_ note: Note) {
        UIPasteboard.general.string = note.displayText
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    // MARK: Settings

    func saveKey(_ key: String) {
        KeychainStore.saveKey(key)
        hasKey = !KeychainStore.readKey().isEmpty
    }
}
