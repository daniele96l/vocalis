import Foundation

/// Fires STT on audio chunks while the user is still holding the hotkey.
/// On release, only the last short tail + any in-flight requests remain.
@MainActor
public final class LiveTranscriber {
    public static let defaultChunkSeconds: Double = 5.0

    private let client: OpenAIClient
    private var tasks: [Int: Task<String, Error>] = [:]
    private var nextIndex = 0
    private var submitted = 0

    public init(client: OpenAIClient) {
        self.client = client
    }

    public var pendingCount: Int { tasks.count }

    public func submit(url: URL) {
        // Skip tiny / silent seals (rotate can race with almost-empty buffers).
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        if size < 800 {
            try? FileManager.default.removeItem(at: url)
            return
        }

        let index = nextIndex
        nextIndex += 1
        submitted += 1
        NSLog("Vocalis: live STT chunk #\(index) (\(size) bytes)")

        tasks[index] = Task {
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let result = try await client.transcribe(audioURL: url)
                return result.text
            } catch OpenAIClientError.emptyAudio, OpenAIClientError.emptyTranscript {
                return ""
            } catch {
                // Keep listening; a bad chunk (e.g. old float WAV) must not kill the hold.
                NSLog("Vocalis: live STT chunk failed: \(error.localizedDescription)")
                return ""
            }
        }
    }

    public func cancel() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        nextIndex = 0
        submitted = 0
    }

    public func finishJoined() async throws -> String {
        let ordered = tasks.keys.sorted()
        var parts: [String] = []
        for index in ordered {
            guard let task = tasks[index] else { continue }
            let text = try await task.value
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                parts.append(trimmed)
            }
        }
        tasks.removeAll()
        return Self.join(parts)
    }

    /// Join chunk transcripts; collapse obvious duplicated boundary words.
    public static func join(_ parts: [String]) -> String {
        guard !parts.isEmpty else { return "" }
        var result = parts[0]
        for part in parts.dropFirst() {
            result = merge(result, part)
        }
        return result
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func merge(_ left: String, _ right: String) -> String {
        let leftTokens = left.split(separator: " ").map(String.init)
        let rightTokens = right.split(separator: " ").map(String.init)
        guard !leftTokens.isEmpty, !rightTokens.isEmpty else {
            return left.isEmpty ? right : (right.isEmpty ? left : "\(left) \(right)")
        }
        // Longest overlap of trailing left vs leading right (up to 4 tokens).
        let maxOverlap = min(4, leftTokens.count, rightTokens.count)
        var overlap = 0
        for n in stride(from: maxOverlap, through: 1, by: -1) {
            let a = leftTokens.suffix(n).map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
            let b = rightTokens.prefix(n).map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
            if a == Array(b) {
                overlap = n
                break
            }
        }
        let mergedRight = rightTokens.dropFirst(overlap).joined(separator: " ")
        if mergedRight.isEmpty { return left }
        return "\(left) \(mergedRight)"
    }
}
