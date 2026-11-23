import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Constants shared with Android Stow and Stow Web. Changing a model id here means the
/// three apps stop producing comparable output; see stow/docs/parity.md.
public enum Groq {
    public static let transcriptionURL = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    public static let modelsURL = URL(string: "https://api.groq.com/openai/v1/models")!

    public static let transcribeModel = "whisper-large-v3-turbo"

    /// Groq's free tier rejects larger uploads. Stay clear of the 25 MB ceiling.
    public static let maxUploadBytes: Int64 = 24 * 1024 * 1024

    /// The free tier's daily audio allowance, in seconds (8 hours).
    public static let dailyFreeSeconds = 28_800
}

/// The form fields of a transcription request, in the order Android sends them.
///
/// Same shape as `AudioTranscriber.buildRequest`: `language=en` and `temperature=0` pin
/// Whisper's decoding, `verbose_json` returns the per-segment statistics the quality
/// warning reads, and `prompt` is left out entirely when the jargon dictionary is empty.
public enum TranscriptionRequest {

    public static func fields(jargon: String, model: String = Groq.transcribeModel) -> [(name: String, value: String)] {
        var fields: [(name: String, value: String)] = [
            ("model", model),
            ("language", "en"),
            ("temperature", "0"),
            ("response_format", "verbose_json")
        ]
        let prompt = jargon.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty {
            fields.append(("prompt", prompt))
        }
        return fields
    }

    /// The request without its body. A background upload sends the body from a file,
    /// written by `MultipartFile`, so the two are built separately.
    public static func urlRequest(apiKey: String, boundary: String) -> URLRequest {
        var request = URLRequest(url: Groq.transcriptionURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        return request
    }
}

/// Writes a multipart/form-data body to a file on disk.
///
/// iOS only runs an upload in the background when the body comes from a file, so the
/// audio is copied into the body in chunks and never held in memory whole.
public enum MultipartFile {

    public static func makeBoundary() -> String {
        "stow-\(UUID().uuidString)"
    }

    public static func write(
        to destination: URL,
        boundary: String,
        fields: [(name: String, value: String)],
        fileField: String = "file",
        fileURL: URL,
        fileName: String,
        mimeType: String
    ) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        func writeText(_ text: String) throws {
            try output.write(contentsOf: Data(text.utf8))
        }

        for field in fields {
            try writeText("--\(boundary)\r\n")
            try writeText("Content-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n")
            try writeText("\(field.value)\r\n")
        }

        try writeText("--\(boundary)\r\n")
        try writeText("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(fileName)\"\r\n")
        try writeText("Content-Type: \(mimeType)\r\n\r\n")

        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }

        try writeText("\r\n--\(boundary)--\r\n")
    }
}
