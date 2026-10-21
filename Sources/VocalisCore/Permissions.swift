import AVFoundation
import AppKit
import Combine
import CoreGraphics
import Foundation
import IOKit.hid

public struct PermissionSnapshot: Equatable, Sendable {
    public var microphone: Bool
    public var accessibility: Bool
    /// True only after a functional HID tap has received a key (not IOHID/CGPreflight alone —
    /// those can false-positive when Vocalis is absent from System Settings).
    public var inputMonitoring: Bool
    public var eventTapInstalled: Bool

    public var allCriticalGranted: Bool {
        microphone && accessibility
    }

    public var hotkeyReady: Bool {
        inputMonitoring && eventTapInstalled
    }
}

public enum AppInstallProbe {
    public static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.daniele96l.vocalis"
    }

    /// Path of the running process's .app (or the executable if not bundled).
    public static var runningAppPath: String {
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            return bundle.path
        }
        return Bundle.main.executableURL?.path
            ?? CommandLine.arguments.first
            ?? bundle.path
    }

    public static var isPackagedApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Other Vocalis.app copies on disk (same bundle id), excluding the running one.
    public static func otherInstallPaths() -> [String] {
        let running = (runningAppPath as NSString).standardizingPath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Only warn about real installs — ignore .build packaging artifacts.
        let candidates = [
            "/Applications/Vocalis.app",
            "\(home)/Applications/Vocalis.app",
        ]
        var found: [String] = []
        var seen = Set<String>()
        for path in candidates {
            let standardized = (path as NSString).standardizingPath
            guard standardized != running else { continue }
            guard !seen.contains(standardized) else { continue }
            guard FileManager.default.fileExists(atPath: standardized) else { continue }
            let info = Bundle(path: standardized)?.infoDictionary
            let id = info?["CFBundleIdentifier"] as? String
            if id == nil || id == bundleIdentifier {
                seen.insert(standardized)
                found.append(standardized)
            }
        }
        return found
    }

    public static var preferredManualAddPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let preferred = [
            "\(home)/Applications/Vocalis.app",
            "/Applications/Vocalis.app",
        ]
        for path in preferred where FileManager.default.fileExists(atPath: path) {
            return path
        }
        if isPackagedApp { return runningAppPath }
        return "\(home)/Applications/Vocalis.app"
    }
}

public enum PermissionProbe {
    public static func microphoneGranted() -> Bool {
        // Status is for the running code identity (this process / bundle).
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    public static func accessibilityGranted() -> Bool {
        Paster.isAccessibilityTrusted(prompt: false)
    }

    /// Register with TCC Input Monitoring and surface the system prompt when possible.
    /// Prefer CGRequestListenEventAccess (adds the .app to the list); IOHID as backup;
    /// a probe HID tap also forces TCC to notice the client.
    @discardableResult
    public static func requestInputMonitoring() -> Bool {
        // CG APIs bind to the running code signature / bundle — must be the packaged .app.
        let cgGranted = CGRequestListenEventAccess()
        let iohidGranted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        // Creating (or failing to create) a listen-only HID tap is what often makes the
        // app appear under Privacy & Security → Input Monitoring.
        _ = canCreateListenOnlyHIDTap()
        return cgGranted || iohidGranted || CGPreflightListenEventAccess()
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
    @Published public private(set) var runningAppPath: String = AppInstallProbe.runningAppPath
    @Published public private(set) var duplicateInstallWarning: String = ""
    @Published public private(set) var inputMonitoringHelp: String = ""
    @Published public private(set) var accessibilityHelp: String = ""
    @Published public private(set) var microphoneHelp: String = ""

    /// Set true when the live HID tap has delivered at least one key event.
    public private(set) var didReceiveKeyViaTap = false

    private var eventTapInstalledProvider: () -> Bool = { false }
    private var hotkeyRetry: (() -> Void)?
    private var didRequestListenOnLaunch = false

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

    public func setHotkeyRetry(_ retry: @escaping () -> Void) {
        hotkeyRetry = retry
    }

    public func markKeyEventReceived() {
        if !didReceiveKeyViaTap {
            didReceiveKeyViaTap = true
            refresh()
        }
    }

    /// Soft TCC registration on first Setup / launch so Vocalis appears in Input Monitoring.
    public func ensureInputMonitoringRegistered() {
        guard !didRequestListenOnLaunch else { return }
        guard !didReceiveKeyViaTap else { return }
        didRequestListenOnLaunch = true
        _ = PermissionProbe.requestInputMonitoring()
        hotkeyRetry?()
        refresh()
    }

    public func refresh() {
        let path = AppInstallProbe.runningAppPath
        let others = AppInstallProbe.otherInstallPaths()
        let addPath = AppInstallProbe.preferredManualAddPath
        let packaged = AppInstallProbe.isPackagedApp
        let installed = eventTapInstalledProvider()
        let inputOK = installed && didReceiveKeyViaTap
        let next = PermissionProbe.snapshot(
            eventTapInstalled: installed,
            inputMonitoringFunctional: inputOK
        )

        let dupWarning: String
        if others.isEmpty {
            dupWarning = ""
        } else {
            let list = others.joined(separator: ", ")
            dupWarning =
                "Multiple Vocalis copies found. Using \(path). Grant Mic / Accessibility / Input Monitoring for this copy (also present: \(list)). Quit the other instance if it is running."
        }

        let imHelp: String
        let statusMsg: String
        if next.inputMonitoring {
            imHelp = ""
            statusMsg = ""
        } else {
            imHelp =
                """
                If Vocalis is missing from Input Monitoring: Enable reveals the app in Finder — click + in Settings, select that Vocalis.app (\(addPath)), toggle On. \
                If listed but Off: turn the toggle On. Then return, press any key, Refresh.
                """
            if !packaged {
                statusMsg =
                    "Running unpackaged binary — Input Monitoring may not list it. Install Vocalis.app and relaunch."
            } else if !installed {
                statusMsg =
                    "Hotkey tap not installed — enable Input Monitoring, then press any key."
            } else {
                statusMsg =
                    "Waiting for a key — if Vocalis is missing from Input Monitoring, use + to add \(addPath), toggle On, then press a key."
            }
        }

        let axHelp: String = next.accessibility
            ? ""
            : "Vocalis may already be listed under Accessibility — turn its toggle On, then Refresh."

        let micHelp: String
        if next.microphone {
            micHelp = others.isEmpty
                ? ""
                : "Microphone is granted for this running copy: \(path)."
        } else {
            micHelp = "Grant Microphone for this running copy: \(path)."
        }

        let apply = { [weak self] in
            guard let self else { return }
            self.snapshot = next
            self.runningAppPath = path
            self.duplicateInstallWarning = dupWarning
            self.inputMonitoringHelp = imHelp
            self.accessibilityHelp = axHelp
            self.microphoneHelp = micHelp
            self.hotkeyStatusMessage = statusMsg
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
        openPrivacyPane(legacyQuery: "Privacy_Accessibility", modernPath: "Privacy_Accessibility")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.refresh()
        }
    }

    public func openInputMonitoringSettings(request: Bool = true) {
        if request {
            _ = PermissionProbe.requestInputMonitoring()
            hotkeyRetry?()
            // Help the common case where Vocalis never appears in the list:
            // put the .app path on the pasteboard and reveal it in Finder so the
            // user can click + in Input Monitoring and select / drag it.
            let addURL = URL(fileURLWithPath: AppInstallProbe.preferredManualAddPath)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(addURL.path, forType: .string)
            if FileManager.default.fileExists(atPath: addURL.path) {
                NSWorkspace.shared.activateFileViewerSelecting([addURL])
            }
        }
        openPrivacyPane(legacyQuery: "Privacy_ListenEvent", modernPath: "Privacy_ListenEvent")
        // Reset functional proof so user must re-verify after changing Settings.
        didReceiveKeyViaTap = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.hotkeyRetry?()
            self?.refresh()
        }
    }

    public func openMicrophoneSettings() {
        openPrivacyPane(legacyQuery: "Privacy_Microphone", modernPath: "Privacy_Microphone")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.refresh()
        }
    }

    private func openPrivacyPane(legacyQuery: String, modernPath: String) {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?\(legacyQuery)",
            "x-apple.systempreferences:com.apple.Settings.extension.PrivacySecurity?\(modernPath)",
            "x-apple.systempreferences:com.apple.Settings.PrivacySecurity.extension?\(modernPath)",
        ]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
