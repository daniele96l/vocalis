import Foundation

public struct WispFlowConfig: Equatable, Sendable {
    public var openaiAPIKey: String
    public var baseURL: String
    public var sttModel: String
    public var cleanupModel: String
    public var hotkey: String

    public static let defaultBaseURL = "https://api.openai.com/v1"
    public static let defaultSTTModel = "whisper-1"
    public static let defaultCleanupModel = "gpt-4o-mini"
    public static let defaultHotkey = "rightOption"

    public static var configDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/wispflow", isDirectory: true)
    }

    public static var configFileURL: URL {
        configDirectoryURL.appendingPathComponent("config.toml")
    }

    public init(
        openaiAPIKey: String = "",
        baseURL: String = defaultBaseURL,
        sttModel: String = defaultSTTModel,
        cleanupModel: String = defaultCleanupModel,
        hotkey: String = defaultHotkey
    ) {
        self.openaiAPIKey = openaiAPIKey
        self.baseURL = baseURL
        self.sttModel = sttModel
        self.cleanupModel = cleanupModel
        self.hotkey = hotkey
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

    public static func load() -> WispFlowConfig {
        var config = WispFlowConfig()
        let url = configFileURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return config
        }
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
            default: break
            }
        }
        return config
    }

    public func save() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.configDirectoryURL, withIntermediateDirectories: true)
        let body = """
        # ~/.config/wispflow/config.toml
        # Prefer env OPENAI_API_KEY; file key is fallback
        openai_api_key = "\(openaiAPIKey)"
        base_url = "\(baseURL)"
        stt_model = "\(sttModel)"
        cleanup_model = "\(cleanupModel)"
        hotkey = "\(hotkey)"
        """
        try body.write(to: Self.configFileURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.configFileURL.path)
    }
}
