import StowCore
import SwiftUI

/// The main screen. The result sits at the top and the record button at the bottom,
/// inside thumb reach, because this is used one-handed.
struct RecordView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingHistory = false
    @State private var showingSettings = false

    var body: some View {
        RecordScreen(recorder: model.recorder, showingHistory: $showingHistory, showingSettings: $showingSettings)
            .sheet(isPresented: $showingHistory) { HistoryView().environmentObject(model) }
            .sheet(isPresented: $showingSettings) { SettingsView().environmentObject(model) }
    }
}

/// Split from `RecordView` so the recorder is observed directly and the timer redraws.
private struct RecordScreen: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var recorder: Recorder
    @Binding var showingHistory: Bool
    @Binding var showingSettings: Bool

    var body: some View {
        VStack(spacing: 12) {
            header

            if let banner = model.banner {
                Text(banner)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            resultArea

            if model.waitingCount > 0 && recorder.state == .idle {
                Button("Send \(model.waitingCount) waiting") { model.sendAllWaiting() }
                    .buttonStyle(.bordered)
            }

            Text(usageLine)
                .font(.footnote)
                .foregroundStyle(.secondary)

            controls
        }
        .padding()
    }

    private var header: some View {
        HStack {
            Text(micLine)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button { showingHistory = true } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .accessibilityLabel("History")
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
            .padding(.leading, 12)
        }
        .font(.title3)
    }

    @ViewBuilder
    private var resultArea: some View {
        if recorder.state != .idle {
            VStack {
                Spacer()
                Text(timerText)
                    .font(.system(size: 56, weight: .light, design: .monospaced))
                Text(recorder.state == .paused ? "Paused" : "Recording")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if let note = model.latest {
            NoteCard(note: note)
        } else {
            VStack {
                Spacer()
                Text("Tap Start, talk, tap Stop. The text appears here.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if recorder.state != .idle {
                Button(recorder.state == .paused ? "Resume" : "Pause") {
                    if recorder.state == .paused {
                        recorder.resume()
                    } else {
                        recorder.pause()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }

            Button {
                model.toggleRecording()
            } label: {
                Text(recorder.state == .idle ? "Start Recording" : "Stop Recording")
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 96)
            }
            .buttonStyle(.borderedProminent)
            .tint(recorder.state == .idle ? Color.accentColor : Color.red)
        }
    }

    private var timerText: String {
        let seconds = recorder.elapsedSeconds
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var micLine: String {
        guard recorder.state != .idle else { return "" }
        return "Mic: \(recorder.micLabel ?? "unknown") · 16 kHz"
    }

    private var usageLine: String {
        let seconds = model.secondsToday
        let percent = Int(Double(seconds) / Double(Groq.dailyFreeSeconds) * 100)
        return "Today's usage: \(seconds / 60)m (\(percent)% of 8h Groq free limit)"
    }
}

/// One note: its state while it is on the way, its text once it lands.
struct NoteCard: View {
    @EnvironmentObject private var model: AppModel
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch note.status {
            case .waiting, .uploading:
                Spacer()
                HStack {
                    ProgressView()
                    Text("Uploading and transcribing. You can lock the phone.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()

            case .failed:
                Spacer()
                Text(note.errorMessage ?? "The upload failed. The audio was kept.")
                    .foregroundStyle(.red)
                Button("Send again") { model.send(note.id) }
                    .buttonStyle(.borderedProminent)
                Spacer()

            case .done:
                if let warning = note.qualityWarning {
                    Text("Transcription may be unreliable: \(warning)")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                ScrollView {
                    Text(note.displayText)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("Copy") { model.copy(note) }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    ShareLink(item: note.displayText) {
                        Text("Share")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
