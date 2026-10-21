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

public enum Paster {
    public static func isAccessibilityTrusted(prompt: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Sets clipboard then synthesizes ⌘V. Never call on failure paths.
    @MainActor
    public static func paste(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PasterError.emptyText }
        guard isAccessibilityTrusted(prompt: false) else {
            throw PasterError.accessibilityDenied
        }

        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(trimmed, forType: .string)

        // Small delay so the target app sees the new clipboard.
        Thread.sleep(forTimeInterval: 0.05)

        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // V
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        // Optionally restore previous clipboard after a beat (best-effort).
        if let previous {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(previous, forType: .string)
            }
        }
    }
}
