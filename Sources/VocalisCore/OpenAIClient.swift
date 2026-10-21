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
        case .missingKey: return "Bad key or license"
        case .emptyAudio: return "Empty recording"
        case .emptyTranscript: return "No speech found"
        case .http(let code, let body):
            let lower = body.lowercased()
            if lower.contains("invalid or missing license") {
                return "Invalid license"
            }
            if code == 401 || code == 403 { return "Bad key or license" }
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
    private let config: VocalisConfig
    private let session: URLSession

    public init(config: VocalisConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    private var cleanupSystemPrompt: String {
        let langs = LanguageCatalog.displayNames(for: config.languages)
        return config.resolvedCleanupStyle.systemPrompt(preferredLanguages: langs)
    }

    /// Bearer token: license code (proxy) or provider API key.
    private func authToken(forProvider provider: AuthProvider) throws -> String {
        if config.usesLicense {
            let code = config.resolvedLicenseCode
            guard !code.isEmpty else { throw OpenAIClientError.missingKey }
            return code
        }
        switch provider {
        case .openai:
            let key = config.resolvedAPIKey
            guard !key.isEmpty else { throw OpenAIClientError.missingKey }
            return key
        case .xai:
            let key = config.resolvedXAIKey
            guard !key.isEmpty else { throw OpenAIClientError.missingKey }
            return key
        }
    }

    private enum AuthProvider {
        case openai
        case xai
    }

    private var openAIBaseURL: String {
        if config.usesLicense {
            return "\(config.resolvedLicenseProxyURL)/v1"
        }
        return config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private var xaiSTTURL: URL {
        if config.usesLicense {
            return URL(string: "\(config.resolvedLicenseProxyURL)/v1/stt")!
        }
        return URL(string: "\(ModelCatalog.xaiSTTBaseURL)/stt")!
    }

    public func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        if config.usesGrokSTT {
            return try await transcribeWithGrok(audioURL: audioURL)
        }
        return try await transcribeWithOpenAI(audioURL: audioURL)
    }

    /// Ping the license proxy without spending STT credits.
    /// Pass `code` to test a candidate before (or instead of) saving it.
    public func verifyLicense(code: String? = nil) async throws {
        let resolved = VocalisConfig.normalizeLicenseCode(code ?? config.licenseCode)
        guard !resolved.isEmpty else { throw OpenAIClientError.missingKey }
        let base = (code != nil)
            ? (config.licenseProxyURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? VocalisConfig.defaultLicenseProxyURL
                : config.resolvedLicenseProxyURL)
            : config.resolvedLicenseProxyURL
        guard let url = URL(string: "\(base)/v1/license/verify") else {
            throw OpenAIClientError.decode
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(resolved)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try Self.throwIfNeeded(data: data, response: response)
    }

    private func transcribeWithGrok(audioURL: URL) async throws -> TranscriptionResult {
        let key = try authToken(forProvider: .xai)

        let attrs = try FileManager.default.attributesOfItem(atPath: audioURL.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        if size < 200 { throw OpenAIClientError.emptyAudio }

        // Grok rejects IEEE-float WAVs from AVAudioEngine/AudioQueue ("no samples").
        let uploadURL = try AudioFormatConversion.grokCompatibleWAV(from: audioURL)
        defer {
            if uploadURL != audioURL {
                try? FileManager.default.removeItem(at: uploadURL)
            }
        }

        let localDuration = Self.audioDurationSeconds(url: uploadURL)
        let languages = LanguageCatalog.normalize(config.languages)
        let model = config.sttModel.isEmpty ? ModelCatalog.grokVoiceTranscribe : config.sttModel

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) {
            if let data = string.data(using: .utf8) { body.append(data) }
        }

        // xAI requires non-file fields before `file`.
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(model)\r\n")

        if languages.count == 1, let only = languages.first {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
            append("\(only)\r\n")
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"format\"\r\n\r\n")
            append("true\r\n")
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(try Data(contentsOf: uploadURL))
        append("\r\n")
        append("--\(boundary)--\r\n")

        var request = URLRequest(url: xaiSTTURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
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

        let result = TranscriptionResult(text: trimmed, model: model, durationSeconds: duration)
        UsageLedger.recordSTT(model: result.model, audioSeconds: result.durationSeconds)
        return result
    }

    private func transcribeWithOpenAI(audioURL: URL) async throws -> TranscriptionResult {
        let key = try authToken(forProvider: .openai)

        let attrs = try FileManager.default.attributesOfItem(atPath: audioURL.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        if size < 200 { throw OpenAIClientError.emptyAudio }

        let localDuration = Self.audioDurationSeconds(url: audioURL)
        let languages = LanguageCatalog.normalize(config.languages)

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

        // Single preferred language → hard language pin. Multiple → prompt-only (API takes one code).
        if languages.count == 1, let only = languages.first {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
            append("\(only)\r\n")
        }

        let prompt = LanguageCatalog.transcriptionPrompt(for: languages)
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n")
        append("\(prompt)\r\n")

        let filename = audioURL.pathExtension.isEmpty ? "audio.wav" : "audio.\(audioURL.pathExtension)"
        let mime = audioURL.pathExtension.lowercased() == "wav" ? "audio/wav" : "audio/m4a"
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mime)\r\n\r\n")
        body.append(try Data(contentsOf: audioURL))
        append("\r\n")
        append("--\(boundary)--\r\n")

        let url = URL(string: "\(openAIBaseURL)/audio/transcriptions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
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
        let key = try authToken(forProvider: .openai)

        let style = config.resolvedCleanupStyle
        // Light mode can skip when the transcript already looks polished.
        // Fix / Shape always run — they may still rewrite wording or structure.
        if style == .light, Self.looksAlreadyClean(text) {
            return CleanupResult(
                text: text,
                model: "skipped",
                promptTokens: 0,
                completionTokens: 0
            )
        }

        let maxTokens: Int = {
            switch style {
            case .light: return min(400, max(64, text.count / 2 + 32))
            case .fix: return min(500, max(80, text.count / 2 + 48))
            case .shape: return min(900, max(120, text.count + 80))
            }
        }()

        let payload: [String: Any] = [
            "model": config.cleanupModel,
            "temperature": style == .shape ? 0.2 : 0,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": cleanupSystemPrompt],
                ["role": "user", "content": text],
            ],
        ]
        let url = URL(string: "\(openAIBaseURL)/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        // Prefer snappy paste: if polish is slow, return raw transcript.
        let result: CleanupResult
        do {
            let requestToSend = request
            let session = self.session
            let (data, response) = try await Self.withTimeout(seconds: 2.5) {
                try await session.data(for: requestToSend)
            }
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
                ?? Self.estimateTokens(cleanupSystemPrompt) + Self.estimateTokens(text)
            let completionTokens = (usage?["completion_tokens"] as? Int)
                ?? (usage?["completion_tokens"] as? NSNumber)?.intValue
                ?? Self.estimateTokens(finalText)

            result = CleanupResult(
                text: finalText,
                model: config.cleanupModel,
                promptTokens: promptTokens,
                completionTokens: completionTokens
            )
        } catch {
            NSLog("Vocalis: cleanup timed out or failed — pasting raw transcript")
            return CleanupResult(
                text: text,
                model: "timeout",
                promptTokens: 0,
                completionTokens: 0
            )
        }

        UsageLedger.recordCleanup(
            model: result.model,
            promptTokens: result.promptTokens,
            completionTokens: result.completionTokens
        )
        return result
    }

    private static func looksAlreadyClean(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count < 280 else { return false }
        // No obvious speech artifacts and already punctuated/capitalized.
        let lower = t.lowercased()
        let fillers = [" um ", " uh ", " erm ", " you know "]
        if fillers.contains(where: { lower.contains($0) }) { return false }
        if t.contains("  ") { return false }
        let first = t.first
        let capitalized = first?.isUppercase == true || first?.isNumber == true
        let punctuated = [".", "!", "?", "…"].contains { t.hasSuffix(String($0)) }
        return capitalized && punctuated
    }

    private static func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw OpenAIClientError.http(408, "timeout")
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
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
