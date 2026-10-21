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

public final class OpenAIClient: Sendable {
    public static let cleanupSystemPrompt = """
    You clean dictated speech. Fix typos, punctuation, and casing. Keep the speaker’s meaning and language. Do not add preamble or quotes. Output only the cleaned text.
    """

    private let config: WispFlowConfig
    private let session: URLSession

    public init(config: WispFlowConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func transcribe(audioURL: URL) async throws -> String {
        let key = config.resolvedAPIKey
        guard !key.isEmpty else { throw OpenAIClientError.missingKey }

        let attrs = try FileManager.default.attributesOfItem(atPath: audioURL.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        if size < 200 { throw OpenAIClientError.emptyAudio }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) {
            if let data = string.data(using: .utf8) { body.append(data) }
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(config.sttModel)\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n")
        append("Content-Type: audio/m4a\r\n\r\n")
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
        return trimmed
    }

    public func cleanup(text: String) async throws -> String {
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
        return cleaned.isEmpty ? text : cleaned
    }

    private static func throwIfNeeded(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OpenAIClientError.http(http.statusCode, body)
        }
    }
}
