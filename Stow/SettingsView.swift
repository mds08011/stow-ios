import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var keyEntry = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(model.hasKey ? "Key saved. Paste a new one to replace it." : "Groq API key", text: $keyEntry)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save key") {
                        model.saveKey(keyEntry)
                        keyEntry = ""
                    }
                    .disabled(keyEntry.trimmingCharacters(in: .whitespaces).isEmpty)
                    if model.hasKey {
                        Button("Remove key", role: .destructive) { model.saveKey("") }
                    }
                } header: {
                    Text("Groq API key")
                } footer: {
                    Text("Stored in the iOS Keychain on this device. Sent only to api.groq.com.")
                }

                Section {
                    TextEditor(text: $model.jargon)
                        .frame(minHeight: 120)
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Jargon dictionary")
                } footer: {
                    Text("Comma-separated terms. Sent to Whisper as its prompt so it hears project names and trade terms correctly.")
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
