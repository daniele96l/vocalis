import AVFoundation
import AppKit
import Combine
import CoreGraphics
import Foundation
import IOKit.hid

public struct PermissionSnapshot: Equatable, Sendable {
    public var microphone: Bool
    public var accessibility: Bool
    /// Input Monitoring allowed for this app (TCC granted, or previously verified and not revoked).
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

public enum ListenEventTCCState: Equatable, Sendable {
    /// In the Input Monitoring list and allowed.
    case granted
    /// Typically listed but toggle Off (or explicitly denied).
    case denied
    /// Not yet registered — may be missing from the list.
    case unknown
}

public enum PermissionProbe {
    public static func microphoneGranted() -> Bool {
        // Status is for the running code identity (this process / bundle).
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    public static func accessibilityGranted() -> Bool {
        Paster.isAccessibilityTrusted(prompt: false)
    }

    /// TCC listen-event state (IOHID). Denied usually means Vocalis is listed but Off.
    public static func listenEventTCCState() -> ListenEventTCCState {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .unknown
        }
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

    public static func snapshot(eventTapInstalled: Bool, inputMonitoringOK: Bool) -> PermissionSnapshot {
        PermissionSnapshot(
            microphone: microphoneGranted(),
            accessibility: accessibilityGranted(),
            inputMonitoring: inputMonitoringOK,
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
    /// Returns true only when the live hotkey backend is a HID tap (Input Monitoring).
    private var hidBackendProvider: () -> Bool = { false }
    private var hotkeyRetry: (() -> Void)?
    private var didRequestListenOnLaunch = false
    /// Sticky green for Input Monitoring across refreshes / Settings visits until TCC is Denied.
    private let latchKey = "vocalis.inputMonitoring.latched"

    private var latchedInputMonitoringOK: Bool {
        get { UserDefaults.standard.bool(forKey: latchKey) }
        set { UserDefaults.standard.set(newValue, forKey: latchKey) }
    }

    public init(eventTapInstalledProvider: @escaping () -> Bool = { false }) {
        self.eventTapInstalledProvider = eventTapInstalledProvider
        self.snapshot = PermissionProbe.snapshot(
            eventTapInstalled: false,
            inputMonitoringOK: false
        )
        refresh()
    }

    public func setEventTapInstalledProvider(_ provider: @escaping () -> Bool) {
        eventTapInstalledProvider = provider
        refresh()
    }

    public func setHIDBackendProvider(_ provider: @escaping () -> Bool) {
        hidBackendProvider = provider
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
        let hidBackend = hidBackendProvider()
        let tcc = PermissionProbe.listenEventTCCState()
        let preflight = CGPreflightListenEventAccess()

        // TCC Denied → clear sticky green. Otherwise latch once proven / system-granted
        // so Setup doesn't flip red after every Refresh or Settings visit.
        if tcc == .denied {
            latchedInputMonitoringOK = false
            didReceiveKeyViaTap = false
        } else if tcc == .granted || preflight || (hidBackend && installed && didReceiveKeyViaTap) {
            latchedInputMonitoringOK = true
        }

        let inputOK = tcc != .denied && (
            latchedInputMonitoringOK
                || tcc == .granted
                || preflight
                || (hidBackend && installed && didReceiveKeyViaTap)
        )

        // Quietly re-install HID tap when macOS already granted IM but backend drifted.
        if inputOK, (!installed || !hidBackend) {
            hotkeyRetry?()
        }

        let next = PermissionProbe.snapshot(
            eventTapInstalled: installed || (inputOK && hidBackendProvider()),
            inputMonitoringOK: inputOK
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
            // Soft tip only while the live tap is still coming up — don't turn the row red.
            if !installed || !hidBackend {
                statusMsg = "Input Monitoring is On — reconnecting hotkey tap…"
            } else {
                statusMsg = ""
            }
        } else {
            switch tcc {
            case .denied:
                imHelp =
                    "Vocalis is already in Input Monitoring — turn its toggle On, then return here and Refresh."
            case .granted:
                imHelp =
                    "macOS shows access On. Tap Refresh (or press a key) so Vocalis can attach the hotkey."
            case .unknown:
                imHelp =
                    "Open Input Monitoring. If Vocalis is listed, turn the toggle On. If it’s missing, click + and choose \(addPath), then toggle On and Refresh."
            }
            if !packaged {
                statusMsg =
                    "Running unpackaged binary — Input Monitoring may not list it. Install Vocalis.app and relaunch."
            } else if tcc == .denied {
                statusMsg =
                    "Input Monitoring toggle is Off for Vocalis — flip it On in System Settings."
            } else if !installed {
                statusMsg =
                    "Hotkey tap not installed — turn on Accessibility + Input Monitoring, then Refresh."
            } else {
                statusMsg =
                    "Finish Input Monitoring setup, then Refresh."
            }
        }

        let axHelp: String = next.accessibility
            ? ""
            : "Turn Vocalis On under Accessibility — required for the hotkey while other apps are focused."

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
        let tccBefore = PermissionProbe.listenEventTCCState()
        if request {
            _ = PermissionProbe.requestInputMonitoring()
            hotkeyRetry?()
            // Only reveal Finder when Vocalis is probably missing from the list.
            // If TCC says Denied, it's already listed — user just needs the toggle On.
            if tccBefore == .unknown {
                let addURL = URL(fileURLWithPath: AppInstallProbe.preferredManualAddPath)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(addURL.path, forType: .string)
                if FileManager.default.fileExists(atPath: addURL.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([addURL])
                }
            }
        }
        openPrivacyPane(legacyQuery: "Privacy_ListenEvent", modernPath: "Privacy_ListenEvent")
        // Do not clear the sticky latch here — that made Setup flip green→red after every click.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.hotkeyRetry?()
            self?.refresh()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
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
