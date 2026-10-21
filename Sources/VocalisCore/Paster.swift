import AppKit
import Foundation

public enum PasterError: LocalizedError {
    case accessibilityDenied
    case emptyText

    public var errorDescription: String? {
        switch self {
        case .accessibilityDenied: return "Need Accessibility"
        case .emptyText: return "Empty audio"
        }
    }
}

public enum PasteResult: Equatable, Sendable {
    /// ⌘V was posted; text is also on the clipboard and archived.
    case pasted
    /// Could not synthesize paste — text is on the clipboard + archived for recovery.
    case clipboardOnly
}

public enum Paster {
    public static func isAccessibilityTrusted(prompt: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Always archives + copies to clipboard first, then tries ⌘V once.
    @MainActor
    @discardableResult
    public static func deliver(_ text: String, archiveNote: String = "") throws -> PasteResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PasterError.emptyText }

        DictationArchive.save(trimmed, note: archiveNote.isEmpty ? "deliver" : archiveNote)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(trimmed, forType: .string)
        NSLog("Vocalis: dictation on clipboard (\(trimmed.count) chars)")

        if !isAccessibilityTrusted(prompt: false) {
            _ = isAccessibilityTrusted(prompt: true)
        }
        guard isAccessibilityTrusted(prompt: false) else {
            NSLog("Vocalis: Accessibility off — paste skipped; text kept on clipboard + last_dictation.txt")
            return .clipboardOnly
        }

        Thread.sleep(forTimeInterval: 0.08)

        // One ⌘V only. Posting to both HID + session (and a “retry” pulse) was
        // pasting the same clipboard 4× into the focused field.
        guard postCommandVOnce() else {
            NSLog("Vocalis: could not create ⌘V events — clipboard only")
            return .clipboardOnly
        }

        NSLog("Vocalis: posted ⌘V")
        return .pasted
    }

    private static func postCommandVOnce() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    @MainActor
    public static func paste(_ text: String) throws {
        _ = try deliver(text)
    }
}
