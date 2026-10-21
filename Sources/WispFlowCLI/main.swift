import Foundation
import WispFlowCore

@main
enum WispFlowCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let command = args.first ?? "help"

        switch command {
        case "setup":
            await setup()
        case "start":
            start()
        case "status":
            status()
        case "help", "-h", "--help":
            printHelp()
        default:
            fputs("Unknown command: \(command)\n\n", stderr)
            printHelp()
            exit(1)
        }
    }

    static func printHelp() {
        print(
            """
            wispflow — macOS dictation (Whisper → cleanup → paste)

            Usage:
              wispflow setup     Prompt for OpenAI API key; write ~/.config/wispflow/config.toml
              wispflow start     Launch the WispFlow menubar app
              wispflow status    Show config + permission summary
              wispflow help      Show this help

            Env:
              OPENAI_API_KEY     Preferred over config file key
              AI_GATEWAY_API_KEY Alternate key (OpenAI-compatible gateway)

            Hotkey (default): hold Right Option
            Fallback: set hotkey = "ctrlShiftSpace" in config.toml
            """
        )
    }

    static func setup() async {
        var config = WispFlowConfig.load()
        print("WispFlow setup")
        print("Config path: \(WispFlowConfig.configFileURL.path)")
        print("")

        if let existing = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !existing.isEmpty {
            print("OPENAI_API_KEY is already set in the environment (will be preferred at runtime).")
        }

        let currentHint: String = {
            if config.openaiAPIKey.isEmpty { return "(empty)" }
            let suffix = config.openaiAPIKey.suffix(4)
            return "sk-…\(suffix)"
        }()
        print("Enter OpenAI API key [\(currentHint)] (leave blank to keep): ", terminator: "")
        fflush(stdout)
        let entered = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !entered.isEmpty {
            config.openaiAPIKey = entered
        }

        print("Base URL [\(config.baseURL)]: ", terminator: "")
        fflush(stdout)
        if let base = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty {
            config.baseURL = base
        }

        print("STT model [\(config.sttModel)]: ", terminator: "")
        fflush(stdout)
        if let stt = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !stt.isEmpty {
            config.sttModel = stt
        }

        print("Cleanup model [\(config.cleanupModel)]: ", terminator: "")
        fflush(stdout)
        if let cleanup = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !cleanup.isEmpty {
            config.cleanupModel = cleanup
        }

        print("Hotkey [\(config.hotkey)] (rightOption | ctrlShiftSpace): ", terminator: "")
        fflush(stdout)
        if let hotkey = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !hotkey.isEmpty {
            config.hotkey = hotkey
        }

        do {
            try config.save()
            print("")
            print("Wrote \(WispFlowConfig.configFileURL.path) (chmod 600)")
            if !config.hasAPIKey {
                print("Warning: no API key in file or env. Set OPENAI_API_KEY or re-run setup.")
            }
        } catch {
            fputs("Failed to write config: \(error)\n", stderr)
            exit(1)
        }
    }

    static func start() {
        let candidates = appCandidates()
        for path in candidates {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if path.hasSuffix(".app") {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = [path]
                do {
                    try process.run()
                    print("Started \(path)")
                    return
                } catch {
                    fputs("Failed to open \(path): \(error)\n", stderr)
                }
            } else {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = []
                do {
                    try p.run()
                    print("Started \(path) (pid \(p.processIdentifier))")
                    return
                } catch {
                    fputs("Failed to start \(path): \(error)\n", stderr)
                }
            }
        }
        fputs(
            """
            Could not find WispFlow.app. Build/install first:
              ./Installer/install.sh
            or:
              swift build -c release
              ./Scripts/package-app.sh
            """,
            stderr
        )
        exit(1)
    }

    static func status() {
        let config = WispFlowConfig.load()
        let keySource: String = {
            if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !env.isEmpty {
                return "env OPENAI_API_KEY"
            }
            if let env = ProcessInfo.processInfo.environment["AI_GATEWAY_API_KEY"], !env.isEmpty {
                return "env AI_GATEWAY_API_KEY"
            }
            if !config.openaiAPIKey.isEmpty { return "config.toml" }
            return "missing"
        }()

        print("WispFlow status")
        print("  config:     \(WispFlowConfig.configFileURL.path)")
        print("  config exists: \(FileManager.default.fileExists(atPath: WispFlowConfig.configFileURL.path))")
        print("  api key:    \(keySource)")
        print("  base_url:   \(config.baseURL)")
        print("  stt_model:  \(config.sttModel)")
        print("  cleanup:    \(config.cleanupModel)")
        print("  hotkey:     \(config.hotkey)")
        print("  accessibility trusted: \(Paster.isAccessibilityTrusted(prompt: false))")
        print("  app candidates:")
        for path in appCandidates() {
            let exists = FileManager.default.fileExists(atPath: path)
            print("    \(exists ? "✓" : "·") \(path)")
        }
    }

    static func appCandidates() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths = [
            "/Applications/WispFlow.app",
            "\(home)/Applications/WispFlow.app",
            "\(home)/Developer/wispflow/.build/WispFlow.app",
            "\(home)/Developer/wispflow/.build/release/WispFlow",
            "\(home)/Developer/wispflow/.build/debug/WispFlow",
        ]
        // Relative to this binary (when installed as ~/.local/bin/wispflow sibling to app)
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let binDir = exe.deletingLastPathComponent()
        paths.insert(binDir.appendingPathComponent("WispFlow.app").path, at: 0)
        paths.insert(binDir.deletingLastPathComponent().appendingPathComponent("WispFlow.app").path, at: 1)
        // Also try swift build products next to package
        if let cwd = FileManager.default.currentDirectoryPath as String? {
            paths.append("\(cwd)/.build/WispFlow.app")
            paths.append("\(cwd)/.build/release/WispFlow")
            paths.append("\(cwd)/.build/debug/WispFlow")
        }
        return paths
    }
}
