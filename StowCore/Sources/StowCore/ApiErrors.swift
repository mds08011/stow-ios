import Foundation

/// How long to wait before a retry, and what to tell the user when a call fails.
/// Ported from Android's `RecordingService.retryAfterSeconds` and `describeApiError`,
/// which were ported from Stow Web. See stow/docs/parity.md.
public enum ApiErrors {

    static let maxRetryWaitSeconds = 900
    static let minRetryWaitSeconds = 3
    static let defaultRateLimitWaitSeconds = 12.0
    static let defaultServerErrorWaitSeconds = 6.0

    /// Seconds until a retry could succeed, or 0 when a retry is pointless (a 4xx that
    /// is not 429).
    ///
    /// Groq answers two ways and neither is reliable alone: a `Retry-After` header, and
    /// prose in the error body ("try again in 2m59.56s"). Take the larger and round up,
    /// because retrying a moment early burns another rate-limit slot.
    public static func retryAfterSeconds(header: String?, body: String?, status: Int) -> Int {
        guard status == 429 || status >= 500 else { return 0 }

        var wait = 0.0
        if let header, let value = Double(header.trimmingCharacters(in: .whitespaces)), value > 0 {
            wait = value
        }
        if let prose = proseWait(in: body ?? "") {
            wait = max(wait, prose)
        }
        if wait <= 0 {
            wait = status == 429 ? defaultRateLimitWaitSeconds : defaultServerErrorWaitSeconds
        }
        return min(max(Int(wait.rounded(.up)), minRetryWaitSeconds), maxRetryWaitSeconds)
    }

    /// Parses "try again in 7.66s" or "try again in 2m59.56s".
    static func proseWait(in body: String) -> Double? {
        guard
            let regex = try? NSRegularExpression(
                pattern: #"try again in (?:(\d+)m)?([\d.]+)s"#,
                options: [.caseInsensitive]
            ),
            let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body))
        else { return nil }

        var minutes = 0.0
        if let range = Range(match.range(at: 1), in: body) {
            minutes = Double(body[range]) ?? 0
        }
        guard let range = Range(match.range(at: 2), in: body), let seconds = Double(body[range]) else {
            return nil
        }
        return minutes * 60 + seconds
    }

    /// A non-2xx turned into something worth reading.
    public static func describe(status: Int, body: String?) -> String {
        switch status {
        case 401, 403:
            return "Your Groq API key was rejected. Check it in Settings."
        case 413:
            return "Recording is too large for Groq to accept (limit about 25 MB)."
        case 429:
            return "Groq rate limit reached. The audio was kept."
        case 500...:
            return "Groq had a server error (\(status)). The audio was kept."
        default:
            let detail = (body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "API error \(status)" : "API error \(status)\n\(detail)"
        }
    }
}
