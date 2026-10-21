import AVFoundation
import AppKit
import Combine
import CoreGraphics
import Foundation
import IOKit.hid

public struct PermissionSnapshot: Equatable, Sendable {
    public var microphone: Bool
    public var accessibility: Bool
    /// True only after a functional HID tap has received a key (not IOHID alone —
    /// IOHID/CGPreflight false-positive when Vocalis is absent from System Settings).
    public var inputMonitoring: Bool
    public var eventTapInstalled: Bool

    public var allCriticalGranted: Bool {
        microphone && accessibility
    }

    public var hotkeyReady: Bool {
        inputMonitoring && eventTapInstalled
    }
}

public enum PermissionProbe {
    public static func microphoneGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    public static func accessibilityGranted() -> Bool {
        Paster.isAccessibilityTrusted(prompt: false)
    }

    public static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    /// HID listen-only tap — session taps can succeed with Accessibility alone.
    public static func canCreateListenOnlyHIDTap() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        ) else {
            return false
        }
        CGEvent.tapEnable(tap: tap, enable: false)
        return true
    }

    public static func snapshot(eventTapInstalled: Bool, inputMonitoringFunctional: Bool) -> PermissionSnapshot {
        PermissionSnapshot(
            microphone: microphoneGranted(),
            accessibility: accessibilityGranted(),
            // Functional proof only — never trust IOHID/CGPreflight alone.
            inputMonitoring: inputMonitoringFunctional,
            eventTapInstalled: eventTapInstalled
        )
    }
}

public final class PermissionsModel: ObservableObject {
    @Published public private(set) var snapshot: PermissionSnapshot
    @Published public private(set) var hotkeyStatusMessage: String = ""

    /// Set true when the live HID tap has delivered at least one key event.
    public private(set) var didReceiveKeyViaTap = false

    private var eventTapInstalledProvider: () -> Bool = { false }

    public init(eventTapInstalledProvider: @escaping () -> Bool = { false }) {
        self.eventTapInstalledProvider = eventTapInstalledProvider
        self.snapshot = PermissionProbe.snapshot(
            eventTapInstalled: false,
            inputMonitoringFunctional: false
        )
        refresh()
    }

    public func setEventTapInstalledProvider(_ provider: @escaping () -> Bool) {
        eventTapInstalledProvider = provider
        refresh()
    }

    public func markKeyEventReceived() {
        if !didReceiveKeyViaTap {
            didReceiveKeyViaTap = true
            refresh()
        }
    }

    public func refresh() {
        let installed = eventTapInstalledProvider()
        // Input Monitoring "Granted" only after functional proof (key via HID tap).
        // If tap isn't installed, stay Not granted — Enable opens System Settings.
        let inputOK = installed && didReceiveKeyViaTap
        let next = PermissionProbe.snapshot(
            eventTapInstalled: installed,
            inputMonitoringFunctional: inputOK
        )
        let message: String = {
            if next.inputMonitoring { return "" }
            if !installed {
                return "Hotkey unavailable — enable Input Monitoring for Vocalis, then press any key."
            }
            return "Tap is up — press any key once to verify Input Monitoring."
        }()

        let apply = { [weak self] in
            self?.snapshot = next
            self?.hotkeyStatusMessage = message
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    public func requestMicrophone() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        await MainActor.run { self.refresh() }
    }

    public func openAccessibilitySettings(promptSystem: Bool = true) {
        if promptSystem {
            _ = Paster.isAccessibilityTrusted(prompt: true)
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.refresh()
        }
    }

    public func openInputMonitoringSettings(request: Bool = true) {
        if request {
            _ = PermissionProbe.requestInputMonitoring()
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
        // Reset functional proof so user must re-verify after changing Settings.
        didReceiveKeyViaTap = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.refresh()
        }
    }

    public func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.refresh()
        }
    }
}
