import AVFoundation
import CoreMedia
import Foundation
import WhisperKit

public enum WhisperLocalError: LocalizedError {
    case notReady(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notReady(let msg): return msg
        case .failed(let msg): return msg
        }
    }
}

/// Local OpenAI Whisper via WhisperKit (Core ML). Model downloads once into Application Support.
public actor WhisperLocalClient {
    public static let shared = WhisperLocalClient()

    public static let defaultVariant = "base"
    public static let variantChoices: [(id: String, title: String)] = [
        ("tiny", "tiny — fastest, least accurate"),
        ("base", "base — good balance (recommended)"),
        ("small", "small — better accuracy, larger download"),
    ]

    private var kit: WhisperKit?
    private var loadedVariant: String?

    private init() {}

    nonisolated public static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Vocalis", isDirectory: true)
            .appendingPathComponent("WhisperKit", isDirectory: true)
    }

    /// True if a WhisperKit model folder for this variant already exists on disk.
    nonisolated public static func isModelDownloaded(variant: String = defaultVariant) -> Bool {
        let root = modelsDirectory
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return false }
        let needle = "openai_whisper-\(variant)"
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return false
        }
        for case let url as URL in enumerator {
            if url.lastPathComponent == needle || url.lastPathComponent.contains(needle) {
                return true
            }
        }
        return false
    }

    nonisolated public static func resolveVariant(fromSTTModel sttModel: String, configVariant: String) -> String {
        let m = sttModel.lowercased()
        if m.hasPrefix("local-whisper-") {
            let v = String(m.dropFirst("local-whisper-".count))
            if !v.isEmpty { return v }
        }
        let trimmed = configVariant.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultVariant : trimmed
    }

    /// Download (if needed) and load the Core ML Whisper model. Safe to call repeatedly.
    public func prepare(variant: String = defaultVariant) async throws {
        let variant = variant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.defaultVariant
            : variant
        if kit != nil, loadedVariant == variant {
            return
        }

        try FileManager.default.createDirectory(at: Self.modelsDirectory, withIntermediateDirectories: true)

        NSLog("Vocalis: loading WhisperKit model '\(variant)' (download if missing)…")
        let config = WhisperKitConfig(
            model: variant,
            downloadBase: Self.modelsDirectory,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: true
        )
        let pipe = try await WhisperKit(config)
        self.kit = pipe
        self.loadedVariant = variant
        NSLog("Vocalis: WhisperKit ready (\(variant))")
    }

    public func transcribe(
        audioURL: URL,
        variant: String = defaultVariant,
        languages: [String]
    ) async throws -> TranscriptionResult {
        try await prepare(variant: variant)
        guard let kit else {
            throw WhisperLocalError.notReady("Whisper model not loaded")
        }

        let codes = LanguageCatalog.normalize(languages)
        var options = DecodingOptions()
        options.temperature = 0
        if codes.count == 1, let only = codes.first {
            options.language = only
            options.detectLanguage = false
        } else {
            options.detectLanguage = true
        }

        let wkText: String
        do {
            let raw = try await kit.transcribe(
                audioPath: audioURL.path,
                decodeOptions: options
            )
            wkText = raw.map(\.text).joined(separator: " ")
        } catch {
            throw WhisperLocalError.failed(error.localizedDescription)
        }

        let text = wkText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw OpenAIClientError.emptyTranscript }

        let duration = Self.audioDurationSeconds(url: audioURL)
        let result = TranscriptionResult(
            text: text,
            model: "local-whisper-\(variant)",
            durationSeconds: duration
        )
        UsageLedger.recordSTT(model: result.model, audioSeconds: result.durationSeconds)
        return result
    }

    nonisolated private static func audioDurationSeconds(url: URL) -> Double {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        if seconds.isFinite, seconds > 0 { return seconds }
        return 1
    }
}
