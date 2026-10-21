import AppKit
import Foundation

@MainActor
public final class HotkeyMonitor {
    public var onPushBegan: (() -> Void)?
    public var onPushEnded: (() -> Void)?
    public var onTapStateChanged: ((Bool) -> Void)?
    /// Fires on any key/flags event received through the live monitor (for IM verification).
    public var onAnyKeyEvent: (() -> Void)?

    public private(set) var isTapInstalled = false
    public private(set) var lastStartError: String?
    /// Which backend is delivering events.
    public private(set) var activeBackend: String = "none"

    private var binding: HotkeyBinding
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isHolding = false
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var watchdog: Timer?
    /// Option/Shift alone can flicker flagsChanged and end the hold mid-sentence.
    private var releaseDebounceTask: Task<Void, Never>?
    /// Longer than a typical flagsChanged blip so hold-to-talk survives mid-phrase flicker.
    private let releaseDebounceNs: UInt64 = 350_000_000

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

        // When Input Monitoring is On (TCC granted), prefer HID. Otherwise prefer
        // session tap (Accessibility) — HID tapCreate can return non-nil while Off
        // and then deliver no background events.
        let imOn = PermissionProbe.listenEventTCCState() == .granted
        let locations: [(CGEventTapLocation, String)] = imOn
            ? [(.cghidEventTap, "hid"), (.cgSessionEventTap, "session")]
            : [(.cgSessionEventTap, "session"), (.cghidEventTap, "hid")]


        var installed: CFMachPort?
        var backend = "none"
        for (location, name) in locations {
            if let tap = CGEvent.tapCreate(
                tap: location,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: CGEventMask(mask),
                callback: callback,
                userInfo: refcon
            ) {
                installed = tap
                backend = name
                break
            }
        }

        if installed == nil {
            _ = PermissionProbe.requestInputMonitoring()
            // Retry HID once after requesting IM.
            if let tap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: CGEventMask(mask),
                callback: callback,
                userInfo: refcon
            ) {
                installed = tap
                backend = "hid-retry"
            } else if let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: CGEventMask(mask),
                callback: callback,
                userInfo: refcon
            ) {
                installed = tap
                backend = "session-retry"
            }
        }

        if let tap = installed {
            eventTap = tap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            isTapInstalled = true
            activeBackend = backend
            lastStartError = nil
            onTapStateChanged?(true)
            NSLog("Vocalis: hotkey tap installed (\(backend))")
        } else {
            isTapInstalled = false
            activeBackend = "none"
            lastStartError = "Event tap failed — enable Accessibility + Input Monitoring for Vocalis."
            NSLog("Vocalis: \(lastStartError!)")
            onTapStateChanged?(false)
        }

        // Local monitor: reliable while Vocalis is the active app (window front).
        // Global monitor: other apps focused — needs Input Monitoring on modern macOS.
        installNSEventMonitors()
        startWatchdog()
    }

    public func stop() {
        watchdog?.invalidate()
        watchdog = nil
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        releaseDebounceTask?.cancel()
        releaseDebounceTask = nil
        isHolding = false
        activeBackend = "none"
        if isTapInstalled {
            isTapInstalled = false
            onTapStateChanged?(false)
        }
    }

    private func installNSEventMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            self?.handleNSEvent(event)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            self?.handleNSEvent(event)
        }
    }

    private func startWatchdog() {
        // Event taps can be silently disabled (timeout / user input). Re-enable while running.
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async { [weak self] in
                self?.reenableTapIfNeeded()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func reenableTapIfNeeded() {
        guard let tap = eventTap else { return }
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            NSLog("Vocalis: re-enabled hotkey event tap")
        }
    }

    private func handleNSEvent(_ event: NSEvent) {
        let type: CGEventType
        switch event.type {
        case .keyDown: type = .keyDown
        case .keyUp: type = .keyUp
        case .flagsChanged: type = .flagsChanged
        default: return
        }
        var flags: CGEventFlags = []
        let nsFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if nsFlags.contains(.control) { flags.insert(.maskControl) }
        if nsFlags.contains(.shift) { flags.insert(.maskShift) }
        if nsFlags.contains(.option) { flags.insert(.maskAlternate) }
        if nsFlags.contains(.command) { flags.insert(.maskCommand) }

        onAnyKeyEvent?()
        process(type: type, keyCode: Int64(event.keyCode), flags: flags)
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
                    down = Self.modifierFlag(forKeyCode: target).map { flags.contains($0) } ?? false
                }
            } else if type == .flagsChanged {
                // Other keys' flagsChanged: only treat as release if our modifier bit is gone.
                if let flag = Self.modifierFlag(forKeyCode: target), !flags.contains(flag) {
                    down = false
                } else {
                    return
                }
            } else {
                return
            }
            if down {
                cancelReleaseDebounce()
                updateHold(true)
            } else {
                scheduleReleaseDebounce()
            }

        case .chord(let targetKey, let needsControl, let needsShift, let needsOption, let needsCommand):
            let modsOK =
                flags.contains(.maskControl) == needsControl
                && flags.contains(.maskShift) == needsShift
                && flags.contains(.maskAlternate) == needsOption
                && flags.contains(.maskCommand) == needsCommand

            if type == .flagsChanged {
                if !modsOK { scheduleReleaseDebounce() }
                else { cancelReleaseDebounce() }
                return
            }
            guard keyCode == targetKey else {
                if type == .keyUp && isHolding { scheduleReleaseDebounce() }
                return
            }
            if type == .keyDown && modsOK {
                cancelReleaseDebounce()
                updateHold(true)
            } else if type == .keyUp {
                scheduleReleaseDebounce()
            }
        }
    }

    private func scheduleReleaseDebounce() {
        releaseDebounceTask?.cancel()
        releaseDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.releaseDebounceNs ?? 180_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.updateHold(false)
            }
        }
    }

    private func cancelReleaseDebounce() {
        releaseDebounceTask?.cancel()
        releaseDebounceTask = nil
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
