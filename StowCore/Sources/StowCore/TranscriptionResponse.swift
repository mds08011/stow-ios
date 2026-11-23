import Foundation

/// Groq's `verbose_json` transcription response, reduced to what Stow keeps.
///
/// Port of Android's `TranscriptionResponse`. The per-segment statistics are the only
/// objective signal for telling a clean transcription from a fluent hallucination.
public struct TranscriptionResponse: Equatable {
    public let text: String
    /// Mean of the segments' `avg_logprob`. More negative means less confident.
    public let avgLogprob: Double?
    /// Worst segment `no_speech_prob`. High means mostly silence or noise.
    public let maxNoSpeechProb: Double?
    /// Worst segment `compression_ratio`. High means repetitive, looping output.
    public let maxCompressionRatio: Double?

    public init(text: String, avgLogprob: Double?, maxNoSpeechProb: Double?, maxCompressionRatio: Double?) {
        self.text = text
        self.avgLogprob = avgLogprob
        self.maxNoSpeechProb = maxNoSpeechProb
        self.maxCompressionRatio = maxCompressionRatio
    }

    /// Returns nil only when there is no usable transcript. Missing or malformed
    /// statistics degrade to nil metrics: a diagnostic must never cost the note.
    public static func parse(_ data: Data) -> TranscriptionResponse? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let json = object as? [String: Any],
            let text = json["text"] as? String,
            !text.isEmpty
        else { return nil }

        guard let segments = json["segments"] as? [Any] else {
            return TranscriptionResponse(text: text, avgLogprob: nil, maxNoSpeechProb: nil, maxCompressionRatio: nil)
        }

        var logprobs: [Double] = []
        var maxNoSpeech: Double?
        var maxCompression: Double?

        for case let segment as [String: Any] in segments {
            if let value = number(segment["avg_logprob"]) {
                logprobs.append(value)
            }
            if let value = number(segment["no_speech_prob"]) {
                maxNoSpeech = max(maxNoSpeech ?? value, value)
            }
            if let value = number(segment["compression_ratio"]) {
                maxCompression = max(maxCompression ?? value, value)
            }
        }

        return TranscriptionResponse(
            text: text,
            avgLogprob: logprobs.isEmpty ? nil : logprobs.reduce(0, +) / Double(logprobs.count),
            maxNoSpeechProb: maxNoSpeech,
            maxCompressionRatio: maxCompression
        )
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        return double.isNaN ? nil : double
    }
}

/// Whisper's own decode-failure thresholds (openai/whisper `transcribe.py`), the same
/// ones Android uses. A starting point, to be tuned against real recordings.
public enum QualityCheck {
    public static let logprobLimit = -1.0
    public static let noSpeechLimit = 0.6
    public static let compressionRatioLimit = 2.4

    /// A short reason the transcription is probably unreliable, or nil. Worst symptom first.
    public static func warning(avgLogprob: Double?, maxNoSpeechProb: Double?, maxCompressionRatio: Double?) -> String? {
        if let ratio = maxCompressionRatio, ratio > compressionRatioLimit {
            return "repetitive output"
        }
        if let noSpeech = maxNoSpeechProb, noSpeech > noSpeechLimit {
            return "mostly silence or noise"
        }
        if let logprob = avgLogprob, logprob < logprobLimit {
            return "low confidence"
        }
        return nil
    }
}
