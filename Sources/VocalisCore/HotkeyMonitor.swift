import AppKit
import Foundation

@MainActor
public final class HotkeyMonitor {
    public var onPushBegan: (() -> Void)?
    public var onPushEnded: (() -> Void)?
    public var onTapStateChanged: ((Bool) -> Void)?
    /// Fires on any key/flags event received through the HID tap (for IM verification).
    public var onAnyKeyEvent: (() -> Void)?

    public private(set) var isTapInstalled = false
    public private(set) var lastStartError: String?

    private var binding: HotkeyBinding
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isHolding = false

    public init(binding: HotkeyBinding = .rightOption) {
        self.binding = binding
    }

    public convenience init(mode: HotkeyBinding) {
        self.init(binding: mode)
    }

    public func updateBinding(_ binding: HotkeyBinding) {
        self.binding = binding
        isHolding = false
    }

    public func updateMode(_ mode: HotkeyBinding) {
        updateBinding(mode)
    }

    public func start() {
        stop()
        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }

        // HID tap requires Input Monitoring (session taps can succeed with Accessibility alone).
        var tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: refcon
        )

        if tap == nil {
            // Ask TCC to register this .app under Input Monitoring, then retry once.
            _ = PermissionProbe.requestInputMonitoring()
            tap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: CGEventMask(mask),
                callback: callback,
                userInfo: refcon
            )
        }

        guard let tap else {
            isTapInstalled = false
            lastStartError = "Event tap failed — enable Input Monitoring for Vocalis in System Settings."
            NSLog("Vocalis: \(lastStartError!)")
            onTapStateChanged?(false)
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isTapInstalled = true
        lastStartError = nil
        onTapStateChanged?(true)
    }

    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isHolding = false
        if isTapInstalled {
            isTapInstalled = false
            onTapStateChanged?(false)
        }
    }

    nonisolated private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            DispatchQueue.main.async { [weak self] in
                if let tap = self?.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        DispatchQueue.main.async { [weak self] in
            self?.onAnyKeyEvent?()
            self?.process(type: type, keyCode: keyCode, flags: flags)
        }
        return Unmanaged.passUnretained(event)
    }

    private func process(type: CGEventType, keyCode: Int64, flags: CGEventFlags) {
        switch binding.kind {
        case .modifierOnly(let target):
            let down: Bool
            if keyCode == target {
                if type == .keyUp {
                    down = false
                } else if type == .keyDown {
                    down = true
                } else {
                    // flagsChanged — infer from matching modifier flag
                    down = Self.modifierFlag(forKeyCode: target).map { flags.contains($0) } ?? false
                }
            } else if type == .flagsChanged {
                // Another flag changed; if our modifier flag cleared, release.
                if let flag = Self.modifierFlag(forKeyCode: target), !flags.contains(flag) {
                    down = false
                } else {
                    return
                }
            } else {
                return
            }
            updateHold(down)

        case .chord(let targetKey, let needsControl, let needsShift, let needsOption, let needsCommand):
            let modsOK =
                flags.contains(.maskControl) == needsControl
                && flags.contains(.maskShift) == needsShift
                && flags.contains(.maskAlternate) == needsOption
                && flags.contains(.maskCommand) == needsCommand

            // For chord matching, ignore device-dependent bits by checking required set ⊆ flags
            // and no extra primary modifiers — already handled via equality above.
            if type == .flagsChanged {
                if !modsOK { updateHold(false) }
                return
            }
            guard keyCode == targetKey else {
                if type == .keyUp && isHolding { updateHold(false) }
                return
            }
            if type == .keyDown && modsOK {
                updateHold(true)
            } else if type == .keyUp {
                updateHold(false)
            }
        }
    }

    private static func modifierFlag(forKeyCode code: Int64) -> CGEventFlags? {
        switch code {
        case 58, 61: return .maskAlternate
        case 56, 60: return .maskShift
        case 55, 54: return .maskCommand
        case 59, 62: return .maskControl
        default: return nil
        }
    }

    private func updateHold(_ holding: Bool) {
        if holding && !isHolding {
            isHolding = true
            onPushBegan?()
        } else if !holding && isHolding {
            isHolding = false
            onPushEnded?()
        }
    }
}
