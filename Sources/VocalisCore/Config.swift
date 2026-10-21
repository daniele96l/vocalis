import Foundation

public struct VocalisConfig: Equatable, Sendable {
    public var openaiAPIKey: String
    public var baseURL: String
    public var sttModel: String
    public var cleanupModel: String
    public var hotkey: String
    /// Core Audio device UID; empty = system default input.
    public var inputDeviceID: String
    /// Transcribe ~5s chunks while holding so long dictations finish faster on release.
    public var streamingSTT: Bool

    public static let defaultBaseURL = "https://api.openai.com/v1"
    /// Cheapest widely available file STT; override in Settings anytime.
    public static let defaultSTTModel = "gpt-4o-mini-transcribe"
    public static let defaultCleanupModel = "gpt-4o-mini"
    public static let defaultHotkey = "rightOption"
    public static let defaultStreamingSTT = true

    public static var configDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/vocalis", isDirectory: true)
    }

    public static var configFileURL: URL {
        configDirectoryURL.appendingPathComponent("config.toml")
    }

    /// Pre-rename path; migrated into `configDirectoryURL` on load when needed.
    public static var legacyConfigDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/wispflow", isDirectory: true)
    }

    public static var legacyConfigFileURL: URL {
        legacyConfigDirectoryURL.appendingPathComponent("config.toml")
    }

    public init(
        openaiAPIKey: String = "",
        baseURL: String = defaultBaseURL,
        sttModel: String = defaultSTTModel,
        cleanupModel: String = defaultCleanupModel,
        hotkey: String = defaultHotkey,
        inputDeviceID: String = "",
        streamingSTT: Bool = defaultStreamingSTT
    ) {
        self.openaiAPIKey = openaiAPIKey
        self.baseURL = baseURL
        self.sttModel = sttModel
        self.cleanupModel = cleanupModel
        self.hotkey = hotkey
        self.inputDeviceID = inputDeviceID
        self.streamingSTT = streamingSTT
    }

    /// Env `OPENAI_API_KEY` (or `AI_GATEWAY_API_KEY`) wins over file key.
    public var resolvedAPIKey: String {
        if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !env.isEmpty {
            return env
        }
        if let env = ProcessInfo.processInfo.environment["AI_GATEWAY_API_KEY"], !env.isEmpty {
            return env
        }
        return openaiAPIKey
    }

    public var hasAPIKey: Bool {
        !resolvedAPIKey.isEmpty
    }

    public static func load() -> VocalisConfig {
        migrateLegacyConfigIfNeeded()
        var config = parse(from: configFileURL) ?? VocalisConfig()
        KeyBootstrap.persistDiscoveredKeyIfNeeded(into: &config)
        return config
    }

    public func save() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.configDirectoryURL, withIntermediateDirectories: true)
        let body = """
        # ~/.config/vocalis/config.toml
        # Prefer env OPENAI_API_KEY; file key is fallback
        openai_api_key = "\(openaiAPIKey)"
        base_url = "\(baseURL)"
        stt_model = "\(sttModel)"
        cleanup_model = "\(cleanupModel)"
        hotkey = "\(hotkey)"
        input_device_id = "\(inputDeviceID)"
        streaming_stt = "\(streamingSTT)"
        """
        try body.write(to: Self.configFileURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.configFileURL.path)
    }

    static func parse(from url: URL) -> VocalisConfig? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        var config = VocalisConfig()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            switch key {
            case "openai_api_key": config.openaiAPIKey = value
            case "base_url": config.baseURL = value.isEmpty ? defaultBaseURL : value
            case "stt_model": config.sttModel = value.isEmpty ? defaultSTTModel : value
            case "cleanup_model": config.cleanupModel = value.isEmpty ? defaultCleanupModel : value
            case "hotkey": config.hotkey = value.isEmpty ? defaultHotkey : value
            case "input_device_id": config.inputDeviceID = value
            case "streaming_stt":
                let v = value.lowercased()
                config.streamingSTT = !(v == "false" || v == "0" || v == "no" || v == "off")
            default: break
            }
        }
        return config
    }

    /// Copy `~/.config/wispflow/config.toml` → `~/.config/vocalis/` once if the new path is missing.
    private static func migrateLegacyConfigIfNeeded() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: configFileURL.path),
              fm.fileExists(atPath: legacyConfigFileURL.path) else { return }
        do {
            try fm.createDirectory(at: configDirectoryURL, withIntermediateDirectories: true)
            try fm.copyItem(at: legacyConfigFileURL, to: configFileURL)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFileURL.path)
            if var text = try? String(contentsOf: configFileURL, encoding: .utf8) {
                text = text.replacingOccurrences(of: "~/.config/wispflow/", with: "~/.config/vocalis/")
                try? text.write(to: configFileURL, atomically: true, encoding: .utf8)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFileURL.path)
            }
        } catch {
            NSLog("Vocalis: config migration failed: \(error.localizedDescription)")
        }
    }
}

/// Discovers a local API key and persists it to `~/.config/vocalis/config.toml` once.
/// Never embeds secrets; only reads env / config / common local env files on this Mac.
public enum KeyBootstrap {
    /// Relative to the user's home directory.
    public static let candidateRelativePaths: [String] = [
        "PycharmProjects/backtesto2free/.env.local",
        "PycharmProjects/backtesto2free/_env.local",
        "PycharmProjects/DaniPortfolio/.env.local",
        "PycharmProjects/danieleligato/.env",
        ".env",
        ".env.local",
        "Developer/backtesto2/.env.local",
        "Developer/genesis/.env.local",
        "velomap/.env.local",
    ]

    /// If the resolved key is only in env or a discovered env file, write it into config.toml
    /// so the menubar app does not prompt again. No-op when a file key already exists.
    public static func persistDiscoveredKeyIfNeeded(into config: inout VocalisConfig) {
        if !config.openaiAPIKey.isEmpty { return }

        if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !env.isEmpty {
            config.openaiAPIKey = env
            try? config.save()
            return
        }
        if let env = ProcessInfo.processInfo.environment["AI_GATEWAY_API_KEY"], !env.isEmpty {
            config.openaiAPIKey = env
            try? config.save()
            return
        }

        if let discovered = discoverFromLocalEnvFiles() {
            config.openaiAPIKey = discovered
            try? config.save()
        }
    }

    public static func discoverFromLocalEnvFiles() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for relative in candidateRelativePaths {
            let url = home.appendingPathComponent(relative)
            if let key = readKey(fromEnvFile: url) {
                return key
            }
        }
        return nil
    }

    private static func readKey(fromEnvFile url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") {
                line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            }
            guard line.hasPrefix("OPENAI_API_KEY=") || line.hasPrefix("AI_GATEWAY_API_KEY=") else { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            if value.isEmpty { continue }
            if value.hasPrefix("your") || value.hasPrefix("sk-...") || value.hasPrefix("CHANGE") { continue }
            return value
        }
        return nil
    }
}
