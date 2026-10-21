import Foundation

/// Published OpenAI list prices used for local estimates (USD).
/// Approximate Settings “Estimated” figures — not an invoice.
public enum OpenAIPricing {
    public static let gpt4oMiniInputUSDPerMillion: Double = 0.150
    public static let gpt4oMiniOutputUSDPerMillion: Double = 0.600
    public static let gpt4oInputUSDPerMillion: Double = 2.50
    public static let gpt4oOutputUSDPerMillion: Double = 10.0
    public static let gpt41NanoInputUSDPerMillion: Double = 0.10
    public static let gpt41NanoOutputUSDPerMillion: Double = 0.40

    /// Published “estimated cost / minute” for file transcription.
    public static func sttUSDPerMinute(model: String) -> Double {
        let m = model.lowercased()
        if m.hasPrefix("grok-voice-transcribe") || (m.hasPrefix("grok-") && m.contains("transcribe")) {
            return 0.10 / 60.0 // xAI REST: $0.10/hr
        }
        switch m {
        case "gpt-4o-mini-transcribe": return 0.003
        case "gpt-transcribe": return 0.0045
        case "gpt-4o-transcribe", "gpt-4o-transcribe-diarize", "whisper-1": return 0.006
        default: return 0.006
        }
    }

    public static func estimateSTT(model: String, durationSeconds: Double) -> Double {
        let minutes = max(durationSeconds, 0) / 60.0
        return minutes * sttUSDPerMinute(model: model)
    }

    public static func estimateCleanup(model: String, promptTokens: Int, completionTokens: Int) -> Double {
        if !ModelCatalog.isCleanupEnabled(model) { return 0 }
        let (inRate, outRate) = cleanupRates(model: model)
        let input = Double(max(promptTokens, 0)) / 1_000_000.0 * inRate
        let output = Double(max(completionTokens, 0)) / 1_000_000.0 * outRate
        return input + output
    }

    private static func cleanupRates(model: String) -> (Double, Double) {
        switch model.lowercased() {
        case "gpt-4o":
            return (gpt4oInputUSDPerMillion, gpt4oOutputUSDPerMillion)
        case "gpt-4.1-nano":
            return (gpt41NanoInputUSDPerMillion, gpt41NanoOutputUSDPerMillion)
        default:
            return (gpt4oMiniInputUSDPerMillion, gpt4oMiniOutputUSDPerMillion)
        }
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
