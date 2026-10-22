import Foundation

public enum WhistleLocalError: LocalizedError {
    case unsupportedArch
    case downloadFailed(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedArch: return "Whistle needs Apple Silicon (macos-arm64)"
        case .downloadFailed(let msg): return msg
        case .failed(let msg): return msg
        }
    }
}

/// Local STT via Cactus Whistle (https://cactuscompute.com/blog/whistle) — 16.9 MB `.cact` + Needle engine.
public enum WhistleLocalClient {
    public static let sttModelID = ModelCatalog.localWhistle

    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Vocalis", isDirectory: true)
            .appendingPathComponent("Whistle", isDirectory: true)
    }

    public static var modelURL: URL {
        supportDirectory.appendingPathComponent("whistle.cact")
    }

    public static var engineDirectory: URL {
        supportDirectory.appendingPathComponent("macos-arm64", isDirectory: true)
    }

    public static var engineURL: URL {
        engineDirectory.appendingPathComponent("needle")
    }

    public static var isReady: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: modelURL.path) && fm.isExecutableFile(atPath: engineURL.path)
    }

    public static var isModelDownloaded: Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
    }

    public static var isEngineDownloaded: Bool {
        FileManager.default.isExecutableFile(atPath: engineURL.path)
    }

    /// Download `whistle.cact` + `macos-arm64/needle` if missing (~18 MB total).
    public static func prepare() async throws {
#if arch(arm64)
        let fm = FileManager.default
        try fm.createDirectory(at: engineDirectory, withIntermediateDirectories: true)

        if !fm.fileExists(atPath: modelURL.path) {
            NSLog("Vocalis: downloading Whistle model…")
            try await download(
                from: URL(string: "https://huggingface.co/Cactus-Compute/whistle/resolve/main/whistle.cact")!,
                to: modelURL
            )
        }

        if !fm.isExecutableFile(atPath: engineURL.path) {
            NSLog("Vocalis: downloading Needle engine (macos-arm64)…")
            try await download(
                from: URL(string: "https://huggingface.co/Cactus-Compute/needle3/resolve/main/macos-arm64/needle")!,
                to: engineURL
            )
            try fm.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: engineURL.path
            )
        }
        NSLog("Vocalis: Whistle ready at \(supportDirectory.path)")
#else
        throw WhistleLocalError.unsupportedArch
#endif
    }

    public static func transcribe(audioURL: URL, languages: [String]) async throws -> TranscriptionResult {
        try await prepare()

        var args = [
            "--model", modelURL.path,
            "--audio", audioURL.path,
        ]
        let codes = LanguageCatalog.normalize(languages)
        // Whistle: en, de, fr, es, it, nl, pl
        let supported = Set(["en", "de", "fr", "es", "it", "nl", "pl"])
        if codes.count == 1, let only = codes.first, supported.contains(only) {
            args += ["--audio-language", only]
        }

        let jsonText = try await runNeedle(arguments: args)
        guard let data = jsonText.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String else {
            throw WhistleLocalError.failed("Bad Whistle output: \(jsonText.prefix(200))")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw OpenAIClientError.emptyTranscript }

        let duration = audioDurationSeconds(url: audioURL)
        let result = TranscriptionResult(
            text: trimmed,
            model: sttModelID,
            durationSeconds: duration
        )
        UsageLedger.recordSTT(model: result.model, audioSeconds: result.durationSeconds)
        return result
    }

    private static func runNeedle(arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let proc = Process()
                    proc.executableURL = engineURL
                    proc.arguments = arguments
                    let out = Pipe()
                    let err = Pipe()
                    proc.standardOutput = out
                    proc.standardError = err
                    try proc.run()
                    proc.waitUntilExit()
                    let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    if proc.terminationStatus != 0 {
                        continuation.resume(
                            throwing: WhistleLocalError.failed(
                                stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? "Whistle exit \(proc.terminationStatus)"
                                    : String(stderr.prefix(240))
                            )
                        )
                        return
                    }
                    let line = stdout
                        .split(whereSeparator: \.isNewline)
                        .map(String.init)
                        .last(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") })
                        ?? stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: line)
                } catch {
                    continuation.resume(throwing: WhistleLocalError.failed(error.localizedDescription))
                }
            }
        }
    }

    private static func download(from url: URL, to dest: URL) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 600
        request.setValue("Vocalis/macOS", forHTTPHeaderField: "User-Agent")
        let (tmpURL, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WhistleLocalError.downloadFailed("HTTP \(http.statusCode) for \(url.lastPathComponent)")
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmpURL, to: dest)
    }

    private static func audioDurationSeconds(url: URL) -> Double {
        // Lightweight estimate from WAV size if needed; Process path already has the file.
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.doubleValue ?? 0
        // Rough PCM 16 kHz mono int16 ≈ 32 KB/s
        if size > 44 { return max(0.5, (size - 44) / 32000.0) }
        return 1
    }
}
