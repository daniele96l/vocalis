import AppKit
import Foundation

public enum HotkeyMode: String, Sendable {
    case rightOption
    case ctrlShiftSpace
}

@MainActor
public final class HotkeyMonitor {
    public var onPushBegan: (() -> Void)?
    public var onPushEnded: (() -> Void)?

    private var mode: HotkeyMode
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isHolding = false
    private var rightOptionDown = false
    private var ctrlDown = false
    private var shiftDown = false

    public init(mode: HotkeyMode = .rightOption) {
        self.mode = mode
    }

    public func updateMode(_ mode: HotkeyMode) {
        self.mode = mode
        isHolding = false
        rightOptionDown = false
    }

    public func start() {
        stop()
        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            NSLog("WispFlow: failed to create event tap (grant Accessibility / Input Monitoring)")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
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
    }

    /// CGEvent tap callback — hop to main actor for state.
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
            self?.process(type: type, keyCode: keyCode, flags: flags)
        }
        return Unmanaged.passUnretained(event)
    }

    private func process(type: CGEventType, keyCode: Int64, flags: CGEventFlags) {
        switch mode {
        case .rightOption:
            // Right Option keyCode is 61 (kVK_RightOption)
            if keyCode == 61 {
                if type == .flagsChanged {
                    rightOptionDown = flags.contains(.maskAlternate)
                } else if type == .keyDown {
                    rightOptionDown = true
                } else if type == .keyUp {
                    rightOptionDown = false
                }
            } else if type == .flagsChanged, !flags.contains(.maskAlternate) {
                rightOptionDown = false
            }
            updateHold(rightOptionDown)

        case .ctrlShiftSpace:
            if type == .flagsChanged {
                ctrlDown = flags.contains(.maskControl)
                shiftDown = flags.contains(.maskShift)
                if !(ctrlDown && shiftDown) {
                    updateHold(false)
                }
            } else if keyCode == 49 { // space
                if type == .keyDown && ctrlDown && shiftDown {
                    updateHold(true)
                } else if type == .keyUp {
                    updateHold(false)
                }
            }
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
