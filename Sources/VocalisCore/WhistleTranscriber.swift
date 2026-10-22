import Foundation

public enum WhistleError: LocalizedError, Equatable, Sendable {
    case missingModel
    case missingEngine
    case failed
    case emptyTranscript
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .missingModel: return "No Whistle model"
        case .missingEngine: return "No Whistle engine"
        case .failed: return "Whistle failed"
        case .emptyTranscript: return "Empty audio"
        case .badResponse: return "Bad response"
        }
    }
}

public struct WhistleInstallation: Equatable, Sendable {
    public var modelURL: URL?
    public var engineURL: URL?

    public var isReady: Bool { modelURL != nil && engineURL != nil }
}

/// On-device transcription with the predownloaded Cactus Whistle model (`whistle.cact`)
/// and the Needle runner. Vocalis does not download either file.
public enum WhistleTranscriber {
    public static let supportedLanguages: Set<String> = ["en", "de", "fr", "es", "it", "nl", "pl"]
    public static let minimumModelBytes = 100_000

    private static let platformDirs = [
        "macos-arm64", "macos-x86_64", "linux-arm64", "linux-x86_64", "linux-armv7",
    ]

    public static func installation(
        environment: [String: String]? = nil,
        home: URL? = nil,
        currentDirectory: URL? = nil,
        additionalModelURLs: [URL] = [],
        fileManager: FileManager = .default
    ) -> WhistleInstallation {
        let env = environment ?? ProcessInfo.processInfo.environment
        let homeURL = home ?? fileManager.homeDirectoryForCurrentUser
        let cwd = currentDirectory ?? URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let model = resolveModel(
            environment: env,
            home: homeURL,
            currentDirectory: cwd,
            additionalModelURLs: additionalModelURLs,
            fileManager: fileManager
        )
        let engine = resolveEngine(
            environment: env,
            home: homeURL,
            model: model,
            fileManager: fileManager
        )
        return WhistleInstallation(modelURL: model, engineURL: engine)
    }

    public static func unavailableReason(
        environment: [String: String]? = nil,
        home: URL? = nil
    ) -> String {
        let found = installation(environment: environment, home: home)
        if found.modelURL == nil { return "No Whistle model" }
        return "No Whistle engine"
    }

    public static func statusDetail(
        environment: [String: String]? = nil,
        home: URL? = nil
    ) -> String {
        let found = installation(environment: environment, home: home)
        if let model = found.modelURL, let engine = found.engineURL {
            return "Local model \(shortPath(model)) · engine \(shortPath(engine))"
        }
        if found.modelURL == nil {
            return "Predownloaded model not found. Put whistle.cact in ~/.config/vocalis."
        }
        return "Found \(shortPath(found.modelURL!)) but the needle engine is missing."
    }

    public static func commandArguments(model: URL, audio: URL, languages: [String]) -> [String] {
        var args = ["--model", model.path, "--audio", audio.path]
        let codes = LanguageCatalog.normalize(languages)
        if codes.count == 1, let only = codes.first, supportedLanguages.contains(only) {
            args.append("--audio-language")
            args.append(only)
        }
        return args
    }

    public static func transcriptText(fromEngineOutput output: String) throws -> String {
        guard let start = output.firstIndex(of: "{"),
              let end = output.lastIndex(of: "}"),
              start <= end else {
            throw WhistleError.badResponse
        }
        let slice = Data(output[start...end].utf8)
        guard let json = try? JSONSerialization.jsonObject(with: slice) as? [String: Any],
              let text = json["text"] as? String else {
            throw WhistleError.badResponse
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw WhistleError.emptyTranscript }
        return trimmed
    }

    public static func transcribe(
        audioURL: URL,
        languages: [String],
        installation override: WhistleInstallation? = nil
    ) async throws -> String {
        let found = override ?? installation()
        guard let model = found.modelURL else { throw WhistleError.missingModel }
        guard let engine = found.engineURL else { throw WhistleError.missingEngine }
        let args = commandArguments(model: model, audio: audioURL, languages: languages)
        let output = try await run(engine: engine, arguments: args)
        return try transcriptText(fromEngineOutput: output)
    }

    private static func resolveModel(
        environment: [String: String],
        home: URL,
        currentDirectory: URL,
        additionalModelURLs: [URL],
        fileManager: FileManager
    ) -> URL? {
        if let forced = firstNonEmpty(environment["VOCALIS_WHISTLE_MODEL"], environment["NEEDLE_WHISTLE_WEIGHTS"]) {
            return modelFile(atPath: forced, fileManager: fileManager)
        }

        var candidates: [URL] = [
            home.appendingPathComponent(".config/vocalis/whistle.cact"),
            home.appendingPathComponent(".config/vocalis/models/whistle.cact"),
            home.appendingPathComponent("Library/Application Support/Vocalis/whistle.cact"),
        ]
        candidates.append(contentsOf: additionalModelURLs)
        if let bundled = Bundle.main.url(forResource: "whistle", withExtension: "cact") {
            candidates.append(bundled)
        }
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(exeDir.appendingPathComponent("whistle.cact"))
            candidates.append(exeDir.deletingLastPathComponent().appendingPathComponent("Resources/whistle.cact"))
        }
        candidates.append(currentDirectory.appendingPathComponent("whistle.cact"))
        candidates.append(currentDirectory.appendingPathComponent("models/whistle.cact"))

        for url in candidates {
            if let model = modelFile(atPath: url.path, fileManager: fileManager) {
                return model
            }
        }

        let caches = [
            home.appendingPathComponent(".cache/huggingface/hub/models--Cactus-Compute--whistle"),
            home.appendingPathComponent(".cache/huggingface/hub/models--cactus-compute--whistle"),
            home.appendingPathComponent("Library/Caches/huggingface/hub/models--Cactus-Compute--whistle"),
            home.appendingPathComponent(".cache/cactus-needle"),
        ]
        for root in caches {
            if let found = findFile(named: "whistle.cact", under: root, maxDepth: 4, fileManager: fileManager),
               let model = modelFile(atPath: found.path, fileManager: fileManager) {
                return model
            }
        }
        return nil
    }

    private static func resolveEngine(
        environment: [String: String],
        home: URL,
        model: URL?,
        fileManager: FileManager
    ) -> URL? {
        if let forced = firstNonEmpty(environment["VOCALIS_NEEDLE"], environment["NEEDLE_BIN"]) {
            return engineFile(atPath: forced, fileManager: fileManager)
        }

        var paths: [String] = []
        if let model {
            paths.append(contentsOf: enginePaths(near: model.deletingLastPathComponent()))
            paths.append(contentsOf: enginePaths(near: model.deletingLastPathComponent().deletingLastPathComponent()))
        }
        paths.append(contentsOf: enginePaths(near: home.appendingPathComponent(".config/vocalis")))
        paths.append(home.appendingPathComponent(".local/bin/needle").path)
        paths.append("/opt/homebrew/bin/needle")
        paths.append("/usr/local/bin/needle")
        if let path = environment["PATH"] {
            for dir in path.split(separator: ":") where !dir.isEmpty {
                paths.append(URL(fileURLWithPath: String(dir)).appendingPathComponent("needle").path)
            }
        }
        for path in paths {
            if let engine = engineFile(atPath: path, fileManager: fileManager) {
                return engine
            }
        }
        return nil
    }

    private static func enginePaths(near directory: URL) -> [String] {
        var paths = [
            directory.appendingPathComponent("needle").path,
            directory.appendingPathComponent("needle.exe").path,
        ]
        for platform in platformDirs {
            let folder = directory.appendingPathComponent(platform)
            paths.append(folder.appendingPathComponent("needle").path)
            paths.append(folder.appendingPathComponent("needle.exe").path)
        }
        return paths
    }

    private static func modelFile(atPath path: String, fileManager: FileManager) -> URL? {
        let expanded = (path as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: expanded, isDirectory: &isDir), !isDir.boolValue else { return nil }
        let size = (try? fileManager.attributesOfItem(atPath: expanded)[.size] as? NSNumber)?.intValue ?? 0
        guard size >= minimumModelBytes else { return nil }
        return URL(fileURLWithPath: expanded)
    }

    private static func engineFile(atPath path: String, fileManager: FileManager) -> URL? {
        let expanded = (path as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: expanded, isDirectory: &isDir), !isDir.boolValue else { return nil }
        guard fileManager.isExecutableFile(atPath: expanded) else { return nil }
        return URL(fileURLWithPath: expanded)
    }

    private static func findFile(named name: String, under root: URL, maxDepth: Int, fileManager: FileManager) -> URL? {
        guard maxDepth >= 0 else { return nil }
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        guard let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for child in children where child.lastPathComponent == name {
            var childIsDir: ObjCBool = false
            if fileManager.fileExists(atPath: child.path, isDirectory: &childIsDir), !childIsDir.boolValue {
                return child
            }
        }
        guard maxDepth > 0 else { return nil }
        for child in children {
            var childIsDir: ObjCBool = false
            guard fileManager.fileExists(atPath: child.path, isDirectory: &childIsDir), childIsDir.boolValue else { continue }
            if let found = findFile(named: name, under: child, maxDepth: maxDepth - 1, fileManager: fileManager) {
                return found
            }
        }
        return nil
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func shortPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~/" + path.dropFirst(home.count + 1)
        }
        return path
    }

    private static func run(engine: URL, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let output = try runBlocking(engine: engine, arguments: arguments)
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runBlocking(engine: URL, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = engine
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["NEEDLE_TELEMETRY"] = "0"
        env["DO_NOT_TRACK"] = "1"
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        let outHandle = stdout.fileHandleForReading
        let errHandle = stderr.fileHandleForReading
        let ioQueue = DispatchQueue(label: "vocalis.whistle.io", attributes: .concurrent)
        let outBox = PipeBuffer()
        let errBox = PipeBuffer()
        let group = DispatchGroup()
        group.enter()
        ioQueue.async {
            outBox.set(outHandle.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        ioQueue.async {
            errBox.set(errHandle.readDataToEndOfFile())
            group.leave()
        }

        do {
            try process.run()
        } catch {
            outHandle.closeFile()
            errHandle.closeFile()
            group.wait()
            throw error
        }
        let deadline = Date().addingTimeInterval(90)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            group.wait()
            NSLog("Vocalis: whistle timed out")
            throw WhistleError.failed
        }
        process.waitUntilExit()
        group.wait()

        if process.terminationStatus != 0 {
            let errText = String(data: errBox.get(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            NSLog("Vocalis: whistle failed: \(errText)")
            throw WhistleError.failed
        }
        return String(data: outBox.get(), encoding: .utf8) ?? ""
    }
}

private final class PipeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func set(_ data: Data) {
        lock.lock()
        storage = data
        lock.unlock()
    }

    func get() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
