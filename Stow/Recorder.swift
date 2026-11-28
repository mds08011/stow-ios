import AVFoundation
import Foundation

/// Records one note to an .m4a file.
///
/// Capture settings match Android Stow: 16 kHz mono AAC at 32 kbps, which is what Whisper
/// resamples to anyway and keeps an hour of dictation near 14 MB.
///
/// Recording continues with the screen locked because the app declares the `audio`
/// background mode and holds an active record session. iOS only allows a recording to
/// *start* while the app is in the foreground.
final class Recorder: NSObject, ObservableObject, AVAudioRecorderDelegate {

    enum State {
        case idle
        case recording
        case paused
    }

    struct Finished {
        let fileName: String
        let durationSeconds: Int
        let micLabel: String?
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsedSeconds: Int = 0
    /// The input iOS actually routed to, read back after recording starts. Never a guess
    /// from what happens to be connected.
    @Published private(set) var micLabel: String?

    /// Called on the main queue if iOS terminates recording unexpectedly (e.g. encode error).
    var onUnexpectedStop: ((String) -> Void)?

    private var recorder: AVAudioRecorder?
    private var fileName: String?
    private var timer: Timer?
    private var wasInterrupted = false

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    /// Asks for the microphone if needed, then starts. Calls back on the main queue with
    /// nil on success or a message to show.
    func start(completion: @escaping (String?) -> Void) {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    completion("Microphone access is off. Allow it in Settings, then Stow, then Microphone.")
                    return
                }
                do {
                    try self.beginRecording()
                    completion(nil)
                } catch {
                    self.teardown()
                    completion("Could not start recording: \(error.localizedDescription)")
                }
            }
        }
    }

    private func beginRecording() throws {
        guard state == .idle else { return }

        let session = AVAudioSession.sharedInstance()
        // No Bluetooth option: the phone's own microphone records, as on Android. A
        // connected headset is used for playback only. See docs/plan.md.
        try session.setCategory(.record, mode: .default, options: [])
        try session.setActive(true)

        let name = "audio_\(Int(Date().timeIntervalSince1970 * 1000)).m4a"
        let url = Paths.recording(named: name)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let newRecorder = try AVAudioRecorder(url: url, settings: settings)
        newRecorder.delegate = self
        guard newRecorder.record() else {
            try? FileManager.default.removeItem(at: url)
            throw NSError(
                domain: "Stow",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The recorder refused to start."]
            )
        }

        recorder = newRecorder
        fileName = name
        elapsedSeconds = 0
        state = .recording
        refreshMicLabel()
        startTimer()
    }

    func pause() {
        guard state == .recording else { return }
        recorder?.pause()
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        if recorder?.record() == true {
            state = .recording
        }
    }

    /// Stops and returns the finished file, or nil if nothing was being recorded.
    func stop() -> Finished? {
        guard state != .idle, let recorder, let fileName else { return nil }
        // currentTime excludes paused stretches, so this is the audio actually captured.
        let duration = Int(recorder.currentTime.rounded())
        let label = micLabel
        recorder.delegate = nil
        recorder.stop()
        teardown()
        return Finished(fileName: fileName, durationSeconds: duration, micLabel: label)
    }

    private func teardown() {
        timer?.invalidate()
        timer = nil
        recorder = nil
        fileName = nil
        wasInterrupted = false
        state = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshElapsed()
        }
    }

    /// Also called when the app returns to the foreground, where the timer has been asleep.
    func refreshElapsed() {
        guard let recorder else { return }
        elapsedSeconds = Int(recorder.currentTime)
    }

    private func refreshMicLabel() {
        let input = AVAudioSession.sharedInstance().currentRoute.inputs.first
        micLabel = input.map { port in
            port.portType == .builtInMic ? "Phone mic" : port.portName
        }
    }

    /// A phone call or Siri takes the microphone away. Pause, and pick up again when iOS
    /// says the interruption is over. The audio captured so far stays in the file.
    @objc private func handleInterruption(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        DispatchQueue.main.async {
            switch type {
            case .began:
                if self.state == .recording {
                    self.wasInterrupted = true
                    self.recorder?.pause()
                    self.state = .paused
                }
            case .ended:
                guard self.wasInterrupted else { return }
                self.wasInterrupted = false
                let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
                guard options.contains(.shouldResume) else { return }
                try? AVAudioSession.sharedInstance().setActive(true)
                self.resume()
            @unknown default:
                break
            }
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        DispatchQueue.main.async {
            if self.state != .idle {
                self.refreshMicLabel()
            }
        }
    }

    // MARK: AVAudioRecorderDelegate

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        DispatchQueue.main.async {
            guard self.state != .idle else { return }
            self.teardown()
            let detail = error?.localizedDescription ?? "unknown error"
            self.onUnexpectedStop?("Recording stopped due to an audio error: \(detail)")
        }
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        DispatchQueue.main.async {
            guard self.state != .idle else { return }
            self.teardown()
            if !flag {
                self.onUnexpectedStop?("Recording stopped unexpectedly.")
            }
        }
    }
}
