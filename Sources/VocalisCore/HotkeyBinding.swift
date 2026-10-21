import AppKit
import Foundation

/// Persisted push-to-talk binding. Config string forms:
/// - `rightOption` / `leftOption` / `rightShift` / `leftShift` / `rightCommand` / `leftCommand` / `rightControl` / `leftControl`
/// - `ctrlShiftSpace` (legacy)
/// - `chord:ctrl+shift+49` (modifiers + keyCode)
public struct HotkeyBinding: Equatable, Sendable, Hashable {
    public enum Kind: Equatable, Sendable, Hashable {
        /// Hold a single modifier key (e.g. Right Option).
        case modifierOnly(keyCode: Int64)
        /// Hold modifiers + a non-modifier key.
        case chord(keyCode: Int64, needsControl: Bool, needsShift: Bool, needsOption: Bool, needsCommand: Bool)
    }

    public var kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }

    public static let rightOption = HotkeyBinding(kind: .modifierOnly(keyCode: 61))
    public static let ctrlShiftSpace = HotkeyBinding(
        kind: .chord(keyCode: 49, needsControl: true, needsShift: true, needsOption: false, needsCommand: false)
    )

    public var configValue: String {
        switch kind {
        case .modifierOnly(let code):
            switch code {
            case 61: return "rightOption"
            case 58: return "leftOption"
            case 60: return "rightShift"
            case 56: return "leftShift"
            case 54: return "rightCommand"
            case 55: return "leftCommand"
            case 62: return "rightControl"
            case 59: return "leftControl"
            default: return "mod:\(code)"
            }
        case .chord(let keyCode, let ctrl, let shift, let option, let command):
            if keyCode == 49, ctrl, shift, !option, !command { return "ctrlShiftSpace" }
            var parts: [String] = []
            if ctrl { parts.append("ctrl") }
            if shift { parts.append("shift") }
            if option { parts.append("option") }
            if command { parts.append("cmd") }
            parts.append(String(keyCode))
            return "chord:" + parts.joined(separator: "+")
        }
    }

    public var displayName: String {
        switch kind {
        case .modifierOnly(let code):
            return Self.modifierName(keyCode: code) + " (hold)"
        case .chord(let keyCode, let ctrl, let shift, let option, let command):
            var parts: [String] = []
            if ctrl { parts.append("Ctrl") }
            if shift { parts.append("Shift") }
            if option { parts.append("Option") }
            if command { parts.append("Cmd") }
            parts.append(Self.keyName(keyCode: keyCode))
            return parts.joined(separator: "+") + " (hold)"
        }
    }

    public static func parse(_ value: String) -> HotkeyBinding {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch v {
        case "", "rightOption": return .rightOption
        case "leftOption": return HotkeyBinding(kind: .modifierOnly(keyCode: 58))
        case "rightShift": return HotkeyBinding(kind: .modifierOnly(keyCode: 60))
        case "leftShift": return HotkeyBinding(kind: .modifierOnly(keyCode: 56))
        case "rightCommand": return HotkeyBinding(kind: .modifierOnly(keyCode: 54))
        case "leftCommand": return HotkeyBinding(kind: .modifierOnly(keyCode: 55))
        case "rightControl": return HotkeyBinding(kind: .modifierOnly(keyCode: 62))
        case "leftControl": return HotkeyBinding(kind: .modifierOnly(keyCode: 59))
        case "ctrlShiftSpace": return .ctrlShiftSpace
        default:
            break
        }
        if v.hasPrefix("mod:") {
            let code = Int64(v.dropFirst(4)) ?? 61
            return HotkeyBinding(kind: .modifierOnly(keyCode: code))
        }
        if v.hasPrefix("chord:") {
            let body = String(v.dropFirst(6))
            let tokens = body.split(separator: "+").map(String.init)
            var ctrl = false, shift = false, option = false, command = false
            var keyCode: Int64?
            for t in tokens {
                switch t.lowercased() {
                case "ctrl", "control": ctrl = true
                case "shift": shift = true
                case "option", "alt": option = true
                case "cmd", "command": command = true
                default:
                    if let n = Int64(t) { keyCode = n }
                }
            }
            if let keyCode {
                return HotkeyBinding(
                    kind: .chord(
                        keyCode: keyCode,
                        needsControl: ctrl,
                        needsShift: shift,
                        needsOption: option,
                        needsCommand: command
                    )
                )
            }
        }
        return .rightOption
    }

    /// Build a binding from a live key event (for Settings remapping).
    public static func fromEvent(keyCode: Int64, flags: CGEventFlags, type: CGEventType) -> HotkeyBinding? {
        // Escape cancels
        if keyCode == 53 { return nil }

        let isModifierKey = [54, 55, 56, 58, 59, 60, 61, 62].contains(keyCode)
        if isModifierKey {
            // Only accept on flagsChanged / keyDown when that modifier is down.
            return HotkeyBinding(kind: .modifierOnly(keyCode: keyCode))
        }

        let ctrl = flags.contains(.maskControl)
        let shift = flags.contains(.maskShift)
        let option = flags.contains(.maskAlternate)
        let command = flags.contains(.maskCommand)
        // Require at least one modifier for a normal key (avoid bare letters stealing typing).
        guard ctrl || shift || option || command else { return nil }
        return HotkeyBinding(
            kind: .chord(
                keyCode: keyCode,
                needsControl: ctrl,
                needsShift: shift,
                needsOption: option,
                needsCommand: command
            )
        )
    }

    public static func modifierName(keyCode: Int64) -> String {
        switch keyCode {
        case 61: return "Right Option"
        case 58: return "Left Option"
        case 60: return "Right Shift"
        case 56: return "Left Shift"
        case 54: return "Right Command"
        case 55: return "Left Command"
        case 62: return "Right Control"
        case 59: return "Left Control"
        default: return "Modifier(\(keyCode))"
        }
    }

    public static func keyName(keyCode: Int64) -> String {
        switch keyCode {
        case 49: return "Space"
        case 36: return "Return"
        case 48: return "Tab"
        case 51: return "Delete"
        default:
            // Best-effort letter map for common ANSI keys
            let letters: [Int64: String] = [
                0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
                11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
                31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K",
                45: "N", 46: "M",
            ]
            return letters[keyCode] ?? "Key\(keyCode)"
        }
    }
}
