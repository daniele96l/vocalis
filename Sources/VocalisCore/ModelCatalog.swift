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
        Choice(code: "cs", name: "Czech"),
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

    public static let grokVoiceTranscribe = "grok-voice-transcribe-2.0"
    public static let xaiSTTBaseURL = "https://api.x.ai/v1"

    public static let sttChoices: [Choice] = [
        Choice(
            rawValue: grokVoiceTranscribe,
            title: "Grok Voice Transcribe 2.0",
            detail: "xAI — cheapest ≈ $0.0017/min ($0.10/hr)"
        ),
        Choice(
            rawValue: "gpt-4o-mini-transcribe",
            title: "gpt-4o-mini-transcribe",
            detail: "OpenAI ≈ $0.003/min"
        ),
        Choice(
            rawValue: "gpt-transcribe",
            title: "gpt-transcribe",
            detail: "OpenAI ≈ $0.0045/min"
        ),
        Choice(
            rawValue: "whisper-1",
            title: "whisper-1",
            detail: "OpenAI ≈ $0.006/min"
        ),
        Choice(
            rawValue: "gpt-4o-transcribe",
            title: "gpt-4o-transcribe",
            detail: "OpenAI ≈ $0.006/min"
        ),
    ]

    public static func isGrokSTT(_ model: String) -> Bool {
        let m = model.lowercased()
        return m.hasPrefix("grok-voice-transcribe")
            || (m.hasPrefix("grok-") && m.contains("transcribe"))
    }

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

/// How aggressively the cleanup model rewrites the transcript.
public enum CleanupStyle: String, CaseIterable, Identifiable, Equatable, Sendable {
    /// Typos / punctuation / casing only (current default).
    case light = "light"
    /// Also repair obvious STT mishearings from context.
    case fix = "fix"
    /// Structure the message (lists, parentheses, clear paragraphs).
    case shape = "shape"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .light: return "Light"
        case .fix: return "Fix words"
        case .shape: return "Shape"
        }
    }

    public var detail: String {
        switch self {
        case .light:
            return "Typos, punctuation, casing — keep wording"
        case .fix:
            return "Also replace nonsense / misheard words from context"
        case .shape:
            return "Lists, brackets, structure — as if you typed carefully"
        }
    }

    public static let `default`: CleanupStyle = .light

    public static func parse(_ raw: String) -> CleanupStyle {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return CleanupStyle(rawValue: v) ?? .default
    }

    public func systemPrompt(preferredLanguages: String) -> String {
        let langs = preferredLanguages
        switch self {
        case .light:
            return """
            Fix typos, punctuation, and casing only. Keep the speaker’s words and meaning. \
            Preferred languages: \(langs). Do not translate. Do not add structure (no bullet lists). \
            Output only the cleaned text.
            """
        case .fix:
            return """
            Clean the transcript: fix typos, punctuation, and casing. \
            Also repair obvious speech-to-text mistakes — if a word is nonsense or clearly wrong given the sentence, \
            replace it with the most likely intended word from context. \
            Do not invent new ideas or change the speaker’s intent. \
            Preferred languages: \(langs). Do not translate. \
            Output only the cleaned text.
            """
        case .shape:
            return """
            Turn this spoken transcript into a clear written message the speaker would have typed carefully. \
            Fix typos, punctuation, casing, and obvious misheard words from context. \
            Reorganize when helpful: use bullet lists for enumerations, parentheses for asides, \
            short paragraphs or line breaks for separate thoughts, and light emphasis only when the speech implies it. \
            Keep the speaker’s meaning; do not invent content. Prefer languages: \(langs). Do not translate. \
            Output only the final message text.
            """
        }
    }
}
