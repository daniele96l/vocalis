import Foundation

/// Keeps the last successful transcript on disk so a failed paste never loses text.
public enum DictationArchive {
    public static var lastDictationURL: URL {
        VocalisConfig.configDirectoryURL.appendingPathComponent("last_dictation.txt")
    }

    public static var logURL: URL {
        VocalisConfig.configDirectoryURL.appendingPathComponent("dictations.log")
    }

    /// Writes `last_dictation.txt` and appends a line to `dictations.log`.
    @discardableResult
    public static func save(_ text: String, note: String = "") -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        do {
            let fm = FileManager.default
            try fm.createDirectory(
                at: VocalisConfig.configDirectoryURL,
                withIntermediateDirectories: true
            )
            try trimmed.write(to: lastDictationURL, atomically: true, encoding: .utf8)
            try fm.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: lastDictationURL.path
            )

            let stamp = ISO8601DateFormatter().string(from: Date())
            let meta = note.isEmpty ? "" : " [\(note)]"
            let preview = trimmed.count > 200 ? String(trimmed.prefix(200)) + "…" : trimmed
            let line = "\(stamp)\(meta) (\(trimmed.count) chars)\n\(trimmed)\n---\n"
            if fm.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                if let data = line.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
            } else {
                try line.write(to: logURL, atomically: true, encoding: .utf8)
                try fm.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: logURL.path
                )
            }
            NSLog(
                "Vocalis: saved dictation (\(trimmed.count) chars)\(meta) → \(lastDictationURL.path) · preview: \(preview.replacingOccurrences(of: "\n", with: " "))"
            )
            return true
        } catch {
            NSLog("Vocalis: dictation archive failed: \(error.localizedDescription)")
            return false
        }
    }

    public static func loadLast() -> String? {
        guard let text = try? String(contentsOf: lastDictationURL, encoding: .utf8) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
