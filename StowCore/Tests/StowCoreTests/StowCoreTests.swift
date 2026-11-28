import XCTest
@testable import StowCore

final class RetryAfterTests: XCTestCase {

    func testNonRetryableStatusIsZero() {
        XCTAssertEqual(ApiErrors.retryAfterSeconds(header: "30", body: nil, status: 401), 0)
        XCTAssertEqual(ApiErrors.retryAfterSeconds(header: nil, body: nil, status: 413), 0)
    }

    func testTakesTheLargerOfHeaderAndProse() {
        let body = #"{"error":{"message":"Rate limit reached. Please try again in 2m59.56s."}}"#
        XCTAssertEqual(ApiErrors.retryAfterSeconds(header: "7", body: body, status: 429), 180)
        XCTAssertEqual(ApiErrors.retryAfterSeconds(header: "400", body: body, status: 429), 400)
    }

    func testSecondsOnlyProseRoundsUp() {
        let body = "try again in 7.66s"
        XCTAssertEqual(ApiErrors.retryAfterSeconds(header: nil, body: body, status: 429), 8)
    }

    func testDefaultsWhenTheServerGivesNoHint() {
        XCTAssertEqual(ApiErrors.retryAfterSeconds(header: nil, body: nil, status: 429), 12)
        XCTAssertEqual(ApiErrors.retryAfterSeconds(header: nil, body: "", status: 503), 6)
    }

    func testFloorAndCap() {
        XCTAssertEqual(ApiErrors.retryAfterSeconds(header: "0.2", body: nil, status: 429), 3)
        XCTAssertEqual(ApiErrors.retryAfterSeconds(header: "99999", body: nil, status: 429), 900)
    }
}

final class TranscriptionResponseTests: XCTestCase {

    func testParsesTextAndStatistics() throws {
        let json = """
        {"text":"order the check valves","segments":[
          {"avg_logprob":-0.2,"no_speech_prob":0.01,"compression_ratio":1.1},
          {"avg_logprob":-0.4,"no_speech_prob":0.30,"compression_ratio":1.6}
        ]}
        """
        let parsed = try XCTUnwrap(TranscriptionResponse.parse(Data(json.utf8)))

        XCTAssertEqual(parsed.text, "order the check valves")
        XCTAssertEqual(try XCTUnwrap(parsed.avgLogprob), -0.3, accuracy: 0.0001)
        XCTAssertEqual(parsed.maxNoSpeechProb, 0.30)
        XCTAssertEqual(parsed.maxCompressionRatio, 1.6)
    }

    func testMissingSegmentsStillYieldsTheTranscript() throws {
        let parsed = try XCTUnwrap(TranscriptionResponse.parse(Data(#"{"text":"hello"}"#.utf8)))

        XCTAssertEqual(parsed.text, "hello")
        XCTAssertNil(parsed.avgLogprob)
    }

    func testEmptyOrBrokenBodyIsNil() {
        XCTAssertNil(TranscriptionResponse.parse(Data(#"{"text":""}"#.utf8)))
        XCTAssertNil(TranscriptionResponse.parse(Data("not json".utf8)))
        XCTAssertNil(TranscriptionResponse.parse(Data(#"{"error":{"message":"nope"}}"#.utf8)))
    }

    func testQualityWarningsWorstFirst() {
        XCTAssertEqual(
            QualityCheck.warning(avgLogprob: -1.5, maxNoSpeechProb: 0.9, maxCompressionRatio: 3.0),
            "repetitive output"
        )
        XCTAssertEqual(
            QualityCheck.warning(avgLogprob: -1.5, maxNoSpeechProb: 0.9, maxCompressionRatio: 1.0),
            "mostly silence or noise"
        )
        XCTAssertEqual(
            QualityCheck.warning(avgLogprob: -1.5, maxNoSpeechProb: nil, maxCompressionRatio: nil),
            "low confidence"
        )
        XCTAssertNil(QualityCheck.warning(avgLogprob: -0.3, maxNoSpeechProb: 0.1, maxCompressionRatio: 1.2))
    }
}

final class TranscriptionRequestTests: XCTestCase {

    func testFieldsMatchAndroidAndOmitAnEmptyPrompt() {
        let names = TranscriptionRequest.fields(jargon: "  ").map { $0.name }

        XCTAssertEqual(names, ["model", "language", "temperature", "response_format"])
    }

    func testJargonBecomesThePrompt() {
        let fields = TranscriptionRequest.fields(jargon: " MGD, headworks ")

        XCTAssertEqual(fields.last?.name, "prompt")
        XCTAssertEqual(fields.last?.value, "MGD, headworks")
        XCTAssertEqual(fields.first?.value, "whisper-large-v3-turbo")
    }

    func testRequestCarriesTheKeyAndBoundary() {
        let request = TranscriptionRequest.urlRequest(apiKey: "test-key", boundary: "b0")

        XCTAssertEqual(request.url?.absoluteString, "https://api.groq.com/openai/v1/audio/transcriptions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "multipart/form-data; boundary=b0")
    }

    func testMultipartBodyOnDisk() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let audio = folder.appendingPathComponent("note.m4a")
        try Data("AUDIO-BYTES".utf8).write(to: audio)
        let body = folder.appendingPathComponent("note.multipart")

        try MultipartFile.write(
            to: body,
            boundary: "b0",
            fields: [("model", "m"), ("language", "en")],
            fileURL: audio,
            fileName: "note.m4a",
            mimeType: "audio/mp4"
        )

        let expected = [
            "--b0", "Content-Disposition: form-data; name=\"model\"", "", "m",
            "--b0", "Content-Disposition: form-data; name=\"language\"", "", "en",
            "--b0", "Content-Disposition: form-data; name=\"file\"; filename=\"note.m4a\"",
            "Content-Type: audio/mp4", "", "AUDIO-BYTES",
            "--b0--", ""
        ].joined(separator: "\r\n")
        XCTAssertEqual(String(decoding: try Data(contentsOf: body), as: UTF8.self), expected)
    }
}

final class NoteStoreTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var file: URL { folder.appendingPathComponent("history.json") }

    func testNotesSurviveAReloadNewestFirst() {
        let store = NoteStore(fileURL: file)
        store.add(Note(id: "a", durationSeconds: 10, audioFileName: "a.m4a"))
        store.add(Note(id: "b", durationSeconds: 20, audioFileName: "b.m4a"))

        let reloaded = NoteStore(fileURL: file).all()

        XCTAssertEqual(reloaded.map { $0.id }, ["b", "a"])
        XCTAssertEqual(reloaded.first?.status, .waiting)
    }

    func testUpdateChangesOneNote() {
        let store = NoteStore(fileURL: file)
        store.add(Note(id: "a", durationSeconds: 10, audioFileName: "a.m4a"))

        let updated = store.update(id: "a") {
            $0.status = .done
            $0.rawText = "hello"
        }

        XCTAssertEqual(updated?.rawText, "hello")
        XCTAssertEqual(NoteStore(fileURL: file).note(id: "a")?.status, .done)
        XCTAssertNil(store.update(id: "missing") { $0.status = .failed })
    }

    func testAnUnreadableFileIsSetAsideNotOverwritten() throws {
        try Data("{ this is not history".utf8).write(to: file)

        let store = NoteStore(fileURL: file)
        XCTAssertEqual(store.all().count, 0)
        store.add(Note(id: "a", durationSeconds: 10, audioFileName: nil))

        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("history-unreadable-") })
        XCTAssertEqual(NoteStore(fileURL: file).all().count, 1)
    }

    func testOnlyFinishedNotesCountTowardTheDailyMeter() {
        let store = NoteStore(fileURL: file)
        store.add(Note(id: "a", durationSeconds: 100, status: .done, audioFileName: nil))
        store.add(Note(id: "b", durationSeconds: 50, status: .failed, audioFileName: nil))
        store.add(Note(
            id: "c",
            createdAt: Date(timeIntervalSinceNow: -3 * 86_400),
            durationSeconds: 900,
            status: .done,
            audioFileName: nil
        ))

        XCTAssertEqual(store.secondsTranscribed(on: Date()), 100)
    }
}

final class AudioRetentionTests: XCTestCase {

    func testProtectsUnsentAudioAndKeepsFiveRecentDoneFiles() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let files = (1...7).map { i in
            AudioRetention.StoredFile(
                name: "audio_\(i).m4a",
                modifiedAt: now.addingTimeInterval(-Double(i) * 60)
            )
        } + [
            AudioRetention.StoredFile(
                name: "audio_old_failed.m4a",
                modifiedAt: now.addingTimeInterval(-30 * 86_400)
            ),
            AudioRetention.StoredFile(
                name: "audio_old_done.m4a",
                modifiedAt: now.addingTimeInterval(-10 * 86_400)
            )
        ]

        let notes = [
            Note(id: "failed", durationSeconds: 30, status: .failed, audioFileName: "audio_old_failed.m4a"),
            Note(id: "done", durationSeconds: 30, status: .done, audioFileName: "audio_old_done.m4a")
        ]

        let doomed = Set(AudioRetention.filesToDelete(files: files, notes: notes, now: now))

        XCTAssertFalse(doomed.contains("audio_old_failed.m4a"))
        XCTAssertTrue(doomed.contains("audio_old_done.m4a"))
        XCTAssertTrue(doomed.contains("audio_6.m4a"))
        XCTAssertTrue(doomed.contains("audio_7.m4a"))
        for i in 1...5 {
            XCTAssertFalse(doomed.contains("audio_\(i).m4a"))
        }
    }

    func testKeepFileNameIsNeverDeleted() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = AudioRetention.StoredFile(
            name: "audio_just_done.m4a",
            modifiedAt: now.addingTimeInterval(-30 * 86_400)
        )

        let doomed = AudioRetention.filesToDelete(
            files: [old],
            notes: [],
            now: now,
            keepFileName: "audio_just_done.m4a"
        )

        XCTAssertTrue(doomed.isEmpty)
    }
}
