import StowCore
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [Note] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return model.notes }
        return model.notes.filter { $0.displayText.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered) { note in
                    NavigationLink {
                        NoteCard(note: note)
                            .padding()
                            .navigationTitle(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title(for: note))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text(preview(for: note))
                                .lineLimit(2)
                        }
                    }
                }
                .onDelete { offsets in
                    let doomed = offsets.map { filtered[$0] }
                    doomed.forEach { model.delete($0) }
                }
            }
            .searchable(text: $query)
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay {
                if model.notes.isEmpty {
                    Text("No notes yet.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func title(for note: Note) -> String {
        let minutes = note.durationSeconds / 60
        let seconds = note.durationSeconds % 60
        let when = note.createdAt.formatted(date: .abbreviated, time: .shortened)
        let warning = note.qualityWarning.map { " · ⚠ \($0)" } ?? ""
        return "\(when) · \(minutes)m \(seconds)s\(warning)"
    }

    private func preview(for note: Note) -> String {
        switch note.status {
        case .done:
            return note.displayText
        case .failed:
            return note.errorMessage ?? "Not transcribed. The audio was kept."
        case .waiting, .uploading:
            return "Uploading and transcribing…"
        }
    }
}
