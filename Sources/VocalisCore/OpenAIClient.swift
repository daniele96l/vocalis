import AVFoundation
import CoreMedia
import Foundation

public enum OpenAIClientError: LocalizedError {
    case missingKey
    case emptyAudio
    case emptyTranscript
    case http(Int, String)
    case decode

    public var errorDescription: String? {
        switch self {
        case .missingKey: return "Bad key"
        case .emptyAudio: return "Empty audio"
        case .emptyTranscript: return "Empty audio"
        case .http(let code, _):
            if code == 401 || code == 403 { return "Bad key" }
            return "API \(code)"
        case .decode: return "Bad response"
        }
    }
}

public struct TranscriptionResult: Sendable {
    public let text: String
    public let model: String
    public let durationSeconds: Double
}

public struct CleanupResult: Sendable {
    public let text: String
    public let model: String
    public let promptTokens: Int
    public let completionTokens: Int
}

public final class OpenAIClient: Sendable {
    public static let cleanupSystemPrompt = """
    You clean dictated speech. Fix typos, punctuation, and casing. Keep the speaker’s meaning and language. Do not add preamble or quotes. Output only the cleaned text.
    """

    private let config: VocalisConfig
    private let session: URLSession

    public init(config: VocalisConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        let key = config.resolvedAPIKey
        guard !key.isEmpty else { throw OpenAIClientError.missingKey }

        let attrs = try FileManager.default.attributesOfItem(atPath: audioURL.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        if size < 200 { throw OpenAIClientError.emptyAudio }

        let localDuration = Self.audioDurationSeconds(url: audioURL)

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) {
            if let data = string.data(using: .utf8) { body.append(data) }
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(config.sttModel)\r\n")

        // whisper-1 supports verbose_json (includes duration). Newer STT models use json.
        let responseFormat = config.sttModel.lowercased() == "whisper-1" ? "verbose_json" : "json"
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        append("\(responseFormat)\r\n")

        let filename = audioURL.pathExtension.isEmpty ? "audio.wav" : "audio.\(audioURL.pathExtension)"
        let mime = audioURL.pathExtension.lowercased() == "wav" ? "audio/wav" : "audio/m4a"
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mime)\r\n\r\n")
        body.append(try Data(contentsOf: audioURL))
        append("\r\n")
        append("--\(boundary)--\r\n")

        let url = URL(string: "\(config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/audio/transcriptions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        try Self.throwIfNeeded(data: data, response: response)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw OpenAIClientError.decode
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw OpenAIClientError.emptyTranscript }

        let apiDuration = (json["duration"] as? Double)
            ?? (json["duration"] as? NSNumber)?.doubleValue
        let duration = apiDuration ?? localDuration

        let result = TranscriptionResult(text: trimmed, model: config.sttModel, durationSeconds: duration)
        UsageLedger.recordSTT(model: result.model, audioSeconds: result.durationSeconds)
        return result
    }

    public func cleanup(text: String) async throws -> CleanupResult {
        guard ModelCatalog.isCleanupEnabled(config.cleanupModel) else {
            return CleanupResult(
                text: text,
                model: ModelCatalog.cleanupOff,
                promptTokens: 0,
                completionTokens: 0
            )
        }
        let key = config.resolvedAPIKey
        guard !key.isEmpty else { throw OpenAIClientError.missingKey }

        let payload: [String: Any] = [
            "model": config.cleanupModel,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": Self.cleanupSystemPrompt],
                ["role": "user", "content": text],
            ],
        ]
        let url = URL(string: "\(config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        try Self.throwIfNeeded(data: data, response: response)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw OpenAIClientError.decode
        }
        let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalText = cleaned.isEmpty ? text : cleaned

        let usage = json["usage"] as? [String: Any]
        let promptTokens = (usage?["prompt_tokens"] as? Int)
            ?? (usage?["prompt_tokens"] as? NSNumber)?.intValue
            ?? Self.estimateTokens(Self.cleanupSystemPrompt) + Self.estimateTokens(text)
        let completionTokens = (usage?["completion_tokens"] as? Int)
            ?? (usage?["completion_tokens"] as? NSNumber)?.intValue
            ?? Self.estimateTokens(finalText)

        let result = CleanupResult(
            text: finalText,
            model: config.cleanupModel,
            promptTokens: promptTokens,
            completionTokens: completionTokens
        )
        UsageLedger.recordCleanup(
            model: result.model,
            promptTokens: result.promptTokens,
            completionTokens: result.completionTokens
        )
        return result
    }

    private static func audioDurationSeconds(url: URL) -> Double {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        if seconds.isFinite && seconds > 0 { return seconds }
        // Fallback: rough AAC estimate (~2KB/s at 16kHz mono) if duration unavailable.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = (attrs[.size] as? NSNumber)?.doubleValue, size > 0 {
            return max(0.5, size / 2000.0)
        }
        return 1
    }

    private static func estimateTokens(_ text: String) -> Int {
        max(1, text.count / 4)
    }

    private static func throwIfNeeded(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OpenAIClientError.http(http.statusCode, body)
        }
    }
}
