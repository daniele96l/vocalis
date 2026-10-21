import Foundation

/// ISO-639-1 language codes the user typically speaks (Settings multi-select).
public enum LanguageCatalog {
    public struct Choice: Identifiable, Equatable, Sendable {
        public var id: String { code }
        public var code: String
        public var name: String
    }

    public static let defaultCodes: [String] = ["en", "it"]

    public static let choices: [Choice] = [
        Choice(code: "en", name: "English"),
        Choice(code: "it", name: "Italian"),
        Choice(code: "es", name: "Spanish"),
        Choice(code: "fr", name: "French"),
        Choice(code: "de", name: "German"),
        Choice(code: "pt", name: "Portuguese"),
        Choice(code: "nl", name: "Dutch"),
        Choice(code: "pl", name: "Polish"),
        Choice(code: "ro", name: "Romanian"),
        Choice(code: "uk", name: "Ukrainian"),
        Choice(code: "ru", name: "Russian"),
        Choice(code: "zh", name: "Chinese"),
        Choice(code: "ja", name: "Japanese"),
        Choice(code: "ko", name: "Korean"),
        Choice(code: "ar", name: "Arabic"),
        Choice(code: "hi", name: "Hindi"),
    ]

    public static func normalize(_ codes: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in codes {
            let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard code.count == 2, seen.insert(code).inserted else { continue }
            out.append(code)
        }
        return out.isEmpty ? defaultCodes : out
    }

    public static func displayNames(for codes: [String]) -> String {
        let normalized = normalize(codes)
        let names = normalized.map { code in
            choices.first(where: { $0.code == code })?.name ?? code
        }
        return names.joined(separator: ", ")
    }

    /// Hint for the transcription `prompt` field.
    public static func transcriptionPrompt(for codes: [String]) -> String {
        let names = displayNames(for: codes)
        if normalize(codes).count == 1 {
            return "The speaker uses \(names). Transcribe in \(names)."
        }
        return "The speaker only uses these languages: \(names). Transcribe in the language being spoken; do not switch to another language."
    }
}

/// Preset models shown in Settings. Config still accepts any free-typed id via CLI/toml.
public enum ModelCatalog {
    public struct Choice: Identifiable, Equatable, Sendable {
        public var id: String { rawValue }
        public var rawValue: String
        public var title: String
        public var detail: String
    }

    /// Special cleanup value: paste Whisper text with no second API call.
    public static let cleanupOff = "off"

    public static let sttChoices: [Choice] = [
        Choice(
            rawValue: "gpt-4o-mini-transcribe",
            title: "gpt-4o-mini-transcribe",
            detail: "Cheapest STT ≈ $0.003/min"
        ),
        Choice(
            rawValue: "gpt-transcribe",
            title: "gpt-transcribe",
            detail: "Recommended ≈ $0.0045/min"
        ),
        Choice(
            rawValue: "whisper-1",
            title: "whisper-1",
            detail: "Classic ≈ $0.006/min"
        ),
        Choice(
            rawValue: "gpt-4o-transcribe",
            title: "gpt-4o-transcribe",
            detail: "Higher quality ≈ $0.006/min"
        ),
    ]

    public static let cleanupChoices: [Choice] = [
        Choice(
            rawValue: cleanupOff,
            title: "Off (paste raw transcript)",
            detail: "Free — no second API call"
        ),
        Choice(
            rawValue: "gpt-4o-mini",
            title: "gpt-4o-mini",
            detail: "Default cleanup — usually <$0.0001/dictation"
        ),
        Choice(
            rawValue: "gpt-4.1-nano",
            title: "gpt-4.1-nano",
            detail: "Tiny chat model for light cleanup"
        ),
        Choice(
            rawValue: "gpt-4o",
            title: "gpt-4o",
            detail: "More capable, more expensive"
        ),
    ]

    public static func sttLabel(for raw: String) -> String {
        sttChoices.first { $0.rawValue == raw }?.detail ?? raw
    }

    public static func cleanupLabel(for raw: String) -> String {
        if raw == cleanupOff || raw.isEmpty { return "Off" }
        return cleanupChoices.first { $0.rawValue == raw }?.detail ?? raw
    }

    public static func isCleanupEnabled(_ raw: String) -> Bool {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !(v.isEmpty || v == cleanupOff || v == "none" || v == "false")
    }
}
