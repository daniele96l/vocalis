import Foundation

/// Published OpenAI list prices used for local estimates (USD).
/// Update if OpenAI changes pricing — these are approximate for Settings “Estimated”.
/// - whisper-1 / gpt-4o-transcribe-class STT: $0.006 per minute of audio
/// - gpt-4o-mini chat: $0.150 / 1M input tokens, $0.600 / 1M output tokens
public enum OpenAIPricing {
    public static let whisperUSDPerMinute: Double = 0.006
    public static let gpt4oMiniInputUSDPerMillion: Double = 0.150
    public static let gpt4oMiniOutputUSDPerMillion: Double = 0.600

    public static func estimateSTT(model: String, durationSeconds: Double) -> Double {
        let minutes = max(durationSeconds, 0) / 60.0
        // Same published minute rate for whisper-1; treat other STT models similarly for v1.
        _ = model
        return minutes * whisperUSDPerMinute
    }

    public static func estimateCleanup(model: String, promptTokens: Int, completionTokens: Int) -> Double {
        _ = model
        let input = Double(max(promptTokens, 0)) / 1_000_000.0 * gpt4oMiniInputUSDPerMillion
        let output = Double(max(completionTokens, 0)) / 1_000_000.0 * gpt4oMiniOutputUSDPerMillion
        return input + output
    }
}

public enum UsageKind: String, Codable, Sendable {
    case stt
    case cleanup
}

public struct UsageEvent: Codable, Equatable, Sendable {
    public var id: String
    public var timestamp: Date
    public var kind: UsageKind
    public var model: String
    public var audioSeconds: Double?
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var estimatedUSD: Double
    public var requestOK: Bool

    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        kind: UsageKind,
        model: String,
        audioSeconds: Double? = nil,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        estimatedUSD: Double,
        requestOK: Bool = true
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.model = model
        self.audioSeconds = audioSeconds
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.estimatedUSD = estimatedUSD
        self.requestOK = requestOK
    }
}

public struct UsageTotals: Equatable, Sendable {
    public var requests: Int
    public var sttRequests: Int
    public var cleanupRequests: Int
    public var audioSeconds: Double
    public var promptTokens: Int
    public var completionTokens: Int
    public var estimatedUSD: Double

    public static let zero = UsageTotals(
        requests: 0, sttRequests: 0, cleanupRequests: 0,
        audioSeconds: 0, promptTokens: 0, completionTokens: 0, estimatedUSD: 0
    )

    public var summaryLine: String {
        let cost = String(format: "$%.4f", estimatedUSD)
        var parts: [String] = ["\(requests) req", cost]
        if audioSeconds > 0 {
            parts.insert(String(format: "%.0fs audio", audioSeconds), at: 1)
        }
        if promptTokens + completionTokens > 0 {
            parts.insert("\(promptTokens + completionTokens) tok", at: 1)
        }
        return parts.joined(separator: " · ")
    }
}

public struct UsageReport: Equatable, Sendable {
    public var today: UsageTotals
    public var week: UsageTotals
    public var total: UsageTotals
}

public enum UsageLedger {
    public static var usageFileURL: URL {
        VocalisConfig.configDirectoryURL.appendingPathComponent("usage.jsonl")
    }

    public static func record(_ event: UsageEvent) {
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: VocalisConfig.configDirectoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(event)
            data.append(contentsOf: "\n".utf8)
            if fm.fileExists(atPath: usageFileURL.path) {
                let handle = try FileHandle(forWritingTo: usageFileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: usageFileURL, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: usageFileURL.path)
            }
        } catch {
            NSLog("Vocalis: usage record failed: \(error.localizedDescription)")
        }
    }

    public static func recordSTT(model: String, audioSeconds: Double) {
        let usd = OpenAIPricing.estimateSTT(model: model, durationSeconds: audioSeconds)
        record(UsageEvent(kind: .stt, model: model, audioSeconds: audioSeconds, estimatedUSD: usd))
    }

    public static func recordCleanup(model: String, promptTokens: Int, completionTokens: Int) {
        let usd = OpenAIPricing.estimateCleanup(
            model: model,
            promptTokens: promptTokens,
            completionTokens: completionTokens
        )
        record(UsageEvent(
            kind: .cleanup,
            model: model,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            estimatedUSD: usd
        ))
    }

    public static func loadEvents() -> [UsageEvent] {
        guard let data = try? Data(contentsOf: usageFileURL),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var events: [UsageEvent] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let event = try? decoder.decode(UsageEvent.self, from: lineData) else { continue }
            events.append(event)
        }
        return events
    }

    public static func report(now: Date = Date(), calendar: Calendar = .current) -> UsageReport {
        let events = loadEvents()
        let startOfDay = calendar.startOfDay(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -6, to: startOfDay) ?? startOfDay
        return UsageReport(
            today: totals(events.filter { $0.timestamp >= startOfDay }),
            week: totals(events.filter { $0.timestamp >= weekStart }),
            total: totals(events)
        )
    }

    private static func totals(_ events: [UsageEvent]) -> UsageTotals {
        var t = UsageTotals.zero
        for e in events where e.requestOK {
            t.requests += 1
            t.estimatedUSD += e.estimatedUSD
            switch e.kind {
            case .stt:
                t.sttRequests += 1
                t.audioSeconds += e.audioSeconds ?? 0
            case .cleanup:
                t.cleanupRequests += 1
                t.promptTokens += e.promptTokens ?? 0
                t.completionTokens += e.completionTokens ?? 0
            }
        }
        return t
    }
}
