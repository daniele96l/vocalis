import AppKit
import AVFoundation
import Combine
import SwiftUI
import VocalisCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var controller: DictationController?
    private var homeWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private let permissions = PermissionsModel()
    private let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.accessory)
            _ = VocalisConfig.load()

            let controller = DictationController()
            self.controller = controller
            permissions.setEventTapInstalledProvider { [weak controller] in
                controller?.isHotkeyTapInstalled ?? false
            }
            controller.hotkey.onTapStateChanged = { [weak self] _ in
                guard let app = self else { return }
                Task { @MainActor in
                    app.permissions.refresh()
                    app.syncAppState()
                }
            }
            controller.hotkey.onAnyKeyEvent = { [weak self] in
                self?.permissions.markKeyEventReceived()
            }
            controller.start()
            syncAppState()

            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = item.button {
                if let icon = Self.menubarIcon() {
                    button.image = icon
                } else {
                    button.image = NSImage(
                        systemSymbolName: "waveform.circle.fill",
                        accessibilityDescription: "Vocalis"
                    )
                    button.image?.isTemplate = true
                }
            }
            statusItem = item
            rebuildMenu()

            permissions.refresh()
            syncAppState()

            if CommandLine.arguments.contains("--settings") {
                openSettings()
            } else if CommandLine.arguments.contains("--permissions") {
                openOnboarding()
            } else if CommandLine.arguments.contains("--home") {
                openHome()
            } else if CommandLine.arguments.contains("--demo-listening") {
                openHome()
                controller.bubble.show(.listening)
            } else if CommandLine.arguments.contains("--demo-fixing") {
                openHome()
                controller.bubble.show(.fixing)
            } else {
                maybePromptPermissions()
                maybePromptForMissingKey()
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in
            if !(controller?.isHotkeyTapInstalled ?? false) {
                controller?.retryHotkeyTap()
            }
            permissions.refresh()
            syncAppState()
        }
    }

    @MainActor
    private func syncAppState() {
        let c = controller
        appState.refresh(
            permissions: permissions.snapshot,
            config: c?.config ?? .load(),
            tapInstalled: c?.isHotkeyTapInstalled ?? false,
            tapError: c?.hotkeyStartError
        )
        rebuildMenu()
    }

    private static func menubarIcon() -> NSImage? {
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            Bundle.main.resourceURL?.appendingPathComponent("AppIcon.icns"),
            // When launched as .app/Contents/MacOS/Vocalis
            Bundle.main.bundleURL
                .deletingLastPathComponent() // MacOS
                .appendingPathComponent("Resources/AppIcon.icns"),
        ]
        for case let url? in candidates {
            if let img = NSImage(contentsOf: url) {
                let sized = NSImage(size: NSSize(width: 18, height: 18))
                sized.lockFocus()
                img.draw(
                    in: NSRect(x: 0, y: 0, width: 18, height: 18),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1
                )
                sized.unlockFocus()
                sized.isTemplate = false
                return sized
            }
        }
        return nil
    }

    private func rebuildMenu() {
        guard let item = statusItem else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: "Vocalis", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        let home = NSMenuItem(title: "Open Vocalis", action: #selector(showHome), keyEquivalent: "o")
        home.target = self
        menu.addItem(home)

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let perm = NSMenuItem(title: "Setup / Permissions…", action: #selector(showPermissions), keyEquivalent: "")
        perm.target = self
        menu.addItem(perm)

        menu.addItem(.separator())
        let tip = NSMenuItem(
            title: "Hold \(appState.hotkeyLabel) to dictate",
            action: nil,
            keyEquivalent: ""
        )
        menu.addItem(tip)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Vocalis", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
    }

    @objc private func showHome() { openHome() }
    @objc private func showSettings() { openSettings() }
    @objc private func showPermissions() { openOnboarding() }

    @objc private func quit() {
        Task { @MainActor in
            controller?.stop()
            NSApp.terminate(nil)
        }
    }

    private func maybePromptPermissions() {
        permissions.refresh()
        let snap = permissions.snapshot
        if !snap.allCriticalGranted || !snap.inputMonitoring {
            openOnboarding()
        } else {
            openHome()
        }
    }

    private func maybePromptForMissingKey() {
        if !VocalisConfig.load().hasAPIKey {
            openSettings()
        }
    }

    private func openHome() {
        permissions.refresh()
        MainActor.assumeIsolated { syncAppState() }
        if let existing = homeWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = HomeView(
            state: appState,
            onSettings: { [weak self] in self?.openSettings() },
            onPermissions: { [weak self] in self?.openOnboarding() },
            onRefresh: { [weak self] in
                guard let app = self else { return }
                Task { @MainActor in
                    if !(app.controller?.isHotkeyTapInstalled ?? false) {
                        app.controller?.retryHotkeyTap()
                    }
                    app.permissions.refresh()
                    app.syncAppState()
                }
            }
        )
        present(view, title: "Vocalis", size: NSSize(width: 420, height: 420)) { [weak self] w in
            self?.homeWindow = w
        } onClose: { [weak self] in
            self?.homeWindow = nil
        }
    }

    private func openSettings() {
        MainActor.assumeIsolated { syncAppState() }
        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SettingsView(
            state: appState,
            onHotkeyChanged: { [weak self] binding in
                guard let app = self else { return }
                Task { @MainActor in
                    do {
                        try app.controller?.setHotkey(binding)
                        app.syncAppState()
                    } catch {
                        app.appState.statusMessage = "Could not save hotkey."
                    }
                }
            },
            onSavedKey: { [weak self] in
                guard let app = self else { return }
                Task { @MainActor in
                    app.controller?.reloadConfig()
                    app.syncAppState()
                }
            },
            onOpenPermissions: { [weak self] in self?.openOnboarding() },
            onClose: { [weak self] in
                self?.settingsWindow?.close()
                self?.settingsWindow = nil
            }
        )
        present(view, title: "Vocalis Settings", size: NSSize(width: 480, height: 600)) { [weak self] w in
            self?.settingsWindow = w
        } onClose: { [weak self] in
            self?.settingsWindow = nil
        }
    }

    private func openOnboarding() {
        permissions.refresh()
        MainActor.assumeIsolated { syncAppState() }
        if let existing = onboardingWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = OnboardingView(
            permissions: permissions,
            hotkeyLabel: appState.hotkeyLabel,
            onClose: { [weak self] in
                guard let app = self else { return }
                app.onboardingWindow?.close()
                app.onboardingWindow = nil
                Task { @MainActor in app.syncAppState() }
            }
        )
        present(view, title: "Vocalis Setup", size: NSSize(width: 460, height: 500)) { [weak self] w in
            self?.onboardingWindow = w
        } onClose: { [weak self] in
            self?.onboardingWindow = nil
        }
    }

    private func present<V: View>(
        _ view: V,
        title: String,
        size: NSSize,
        store: @escaping (NSWindow) -> Void,
        onClose: @escaping () -> Void
    ) {
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable]
        window.setContentSize(size)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = WindowCloseDelegate.shared
        WindowCloseDelegate.shared.handlers[ObjectIdentifier(window)] = onClose
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        store(window)
    }
}

final class WindowCloseDelegate: NSObject, NSWindowDelegate {
    static let shared = WindowCloseDelegate()
    var handlers: [ObjectIdentifier: () -> Void] = [:]
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let id = ObjectIdentifier(window)
        handlers[id]?()
        handlers[id] = nil
    }
}

final class AppState: ObservableObject {
    @Published var hotkeyLabel = HotkeyBinding.rightOption.displayName
    @Published var hotkeyConfig = HotkeyBinding.rightOption.configValue
    @Published var keyConfigured = false
    @Published var permissionsOK = false
    @Published var inputMonitoringOK = false
    @Published var micOK = false
    @Published var accessibilityOK = false
    @Published var usageToday = "$0.0000"
    @Published var usageWeek = "$0.0000"
    @Published var usageTotal = "$0.0000"
    @Published var usageTodayDetail = "0 requests"
    @Published var usageWeekDetail = "0 requests"
    @Published var usageTotalDetail = "0 requests"
    @Published var statusMessage = ""
    @Published var hotkeyWarning = ""

    func refresh(
        permissions: PermissionSnapshot?,
        config: VocalisConfig,
        tapInstalled: Bool,
        tapError: String?
    ) {
        let binding = HotkeyBinding.parse(config.hotkey)
        hotkeyLabel = binding.displayName
        hotkeyConfig = binding.configValue
        keyConfigured = config.hasAPIKey
        if let permissions {
            micOK = permissions.microphone
            accessibilityOK = permissions.accessibility
            inputMonitoringOK = permissions.inputMonitoring
            permissionsOK = permissions.allCriticalGranted && permissions.inputMonitoring
            if !permissions.inputMonitoring {
                hotkeyWarning = "Enable Input Monitoring so the hotkey works."
            } else if !tapInstalled {
                hotkeyWarning = tapError ?? "Hotkey tap not active — open Setup and refresh."
            } else {
                hotkeyWarning = ""
            }
        }
        let report = UsageLedger.report()
        usageToday = String(format: "$%.4f", report.today.estimatedUSD)
        usageWeek = String(format: "$%.4f", report.week.estimatedUSD)
        usageTotal = String(format: "$%.4f", report.total.estimatedUSD)
        usageTodayDetail = detail(report.today)
        usageWeekDetail = detail(report.week)
        usageTotalDetail = detail(report.total)
    }

    private func detail(_ t: UsageTotals) -> String {
        if t.requests == 0 { return "0 requests" }
        var parts = ["\(t.requests) requests"]
        if t.audioSeconds > 0 { parts.append(String(format: "%.0fs audio", t.audioSeconds)) }
        let tok = t.promptTokens + t.completionTokens
        if tok > 0 { parts.append("\(tok) tokens") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Home

struct HomeView: View {
    @ObservedObject var state: AppState
    var onSettings: () -> Void
    var onPermissions: () -> Void
    var onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Vocalis")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Text("Hold \(state.hotkeyLabel.replacingOccurrences(of: " (hold)", with: "")) to dictate. Release to clean up and paste.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            statusCard

            HStack(spacing: 10) {
                Button("Settings…") { onSettings() }
                    .buttonStyle(.borderedProminent)
                Button("Permissions…") { onPermissions() }
                Spacer()
                Button("Refresh") { onRefresh() }
                    .controlSize(.small)
            }

            Spacer()
        }
        .padding(24)
        .frame(width: 420, height: 420)
        .onAppear { onRefresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            onRefresh()
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusLine(
                ok: state.permissionsOK,
                title: state.permissionsOK ? "Permissions ready" : "Permissions need attention",
                detail: state.permissionsOK
                    ? "Mic, Accessibility, Input Monitoring look good."
                    : "Open Permissions to finish setup."
            )
            statusLine(
                ok: state.keyConfigured,
                title: state.keyConfigured ? "API key configured" : "API key missing",
                detail: state.keyConfigured ? "Stored on this Mac only." : "Add a key in Settings."
            )
            VStack(alignment: .leading, spacing: 2) {
                Text("Hotkey")
                    .font(.system(size: 12, weight: .semibold))
                Text(state.hotkeyLabel)
                    .font(.system(size: 14, weight: .medium))
                if !state.hotkeyWarning.isEmpty {
                    Text(state.hotkeyWarning)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Usage today")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(state.usageToday) estimated")
                    .font(.system(size: 14, weight: .medium))
                Text(state.usageTodayDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private func statusLine(ok: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var state: AppState
    var onHotkeyChanged: (HotkeyBinding) -> Void
    var onSavedKey: () -> Void
    var onOpenPermissions: () -> Void
    var onClose: () -> Void

    @State private var config = VocalisConfig.load()
    @State private var pastedKey = ""
    @State private var recording = false
    @State private var recordHint = "Click Change hotkey, then hold your new shortcut."
    @State private var localMonitor: Any?

    private var keyConfigured: Bool { config.hasAPIKey }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Settings")
                    .font(.system(size: 22, weight: .bold, design: .rounded))

                sectionHeader("Hotkey")
                VStack(alignment: .leading, spacing: 8) {
                    Text(state.hotkeyLabel)
                        .font(.system(size: 15, weight: .semibold))
                    Text(recording ? "Press new shortcut… (Esc to cancel)" : recordHint)
                        .font(.callout)
                        .foregroundStyle(recording ? Color.orange : Color.secondary)
                    HStack {
                        Button(recording ? "Listening…" : "Change hotkey") {
                            toggleRecording()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(recording)
                        if recording {
                            Button("Cancel") { stopRecording(cancelled: true) }
                        }
                    }
                }
                .padding(12)
                .background(cardBackground)

                sectionHeader("API key")
                VStack(alignment: .leading, spacing: 8) {
                    if keyConfigured {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                            Text("Key configured")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        Text("Stored only in ~/.config/vocalis on this Mac. Never shown in full.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Paste an OpenAI API key to enable dictation.")
                            .foregroundStyle(.secondary)
                    }
                    SecureField(keyConfigured ? "Replace key (optional)" : "sk-…", text: $pastedKey)
                        .textFieldStyle(.roundedBorder)
                    Button("Save key") { saveKey() }
                        .disabled(pastedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(12)
                .background(cardBackground)

                sectionHeader("Usage")
                VStack(alignment: .leading, spacing: 8) {
                    usageRow("Today", cost: state.usageToday, detail: state.usageTodayDetail)
                    usageRow("This week", cost: state.usageWeek, detail: state.usageWeekDetail)
                    usageRow("All time", cost: state.usageTotal, detail: state.usageTotalDetail)
                    Text("Estimated locally (whisper ≈ $0.006/min, gpt-4o-mini ≈ $0.15/$0.60 per 1M in/out). Not OpenAI billing.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(cardBackground)

                sectionHeader("About")
                Text("Vocalis — hold-to-talk dictation for Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if !state.statusMessage.isEmpty {
                    Text(state.statusMessage).font(.callout).foregroundStyle(.secondary)
                }

                HStack {
                    Button("Open Permissions…") { onOpenPermissions() }
                    Spacer()
                    Button("Done") {
                        stopRecording(cancelled: true)
                        onClose()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 480)
        }
        .frame(width: 480, height: 600)
        .onAppear {
            config = VocalisConfig.load()
            state.refresh(
                permissions: nil,
                config: config,
                tapInstalled: true,
                tapError: nil
            )
        }
        .onDisappear { stopRecording(cancelled: true) }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(0.05))
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func usageRow(_ label: String, cost: String, detail: String) -> some View {
        HStack(alignment: .top) {
            Text(label).frame(width: 88, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(cost) estimated").font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func toggleRecording() {
        recording = true
        recordHint = "Hold the keys you want, then release."
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handleRecord(event)
            return nil
        }
    }

    private func handleRecord(_ event: NSEvent) {
        if event.type == .keyDown && event.keyCode == 53 { // Esc
            stopRecording(cancelled: true)
            return
        }
        var cgFlags: CGEventFlags = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) { cgFlags.insert(.maskControl) }
        if flags.contains(.shift) { cgFlags.insert(.maskShift) }
        if flags.contains(.option) { cgFlags.insert(.maskAlternate) }
        if flags.contains(.command) { cgFlags.insert(.maskCommand) }

        let type: CGEventType = event.type == .flagsChanged ? .flagsChanged : .keyDown
        if event.type == .keyDown || (event.type == .flagsChanged && isModifierKeyCode(Int64(event.keyCode))) {
            if event.type == .flagsChanged {
                let down =
                    flags.contains(.option) || flags.contains(.shift)
                    || flags.contains(.control) || flags.contains(.command)
                if !down { return }
            }
            if let binding = HotkeyBinding.fromEvent(
                keyCode: Int64(event.keyCode),
                flags: cgFlags,
                type: type
            ) {
                stopRecording(cancelled: false)
                state.hotkeyLabel = binding.displayName
                state.statusMessage = "Hotkey updated."
                onHotkeyChanged(binding)
            }
        }
    }

    private func isModifierKeyCode(_ code: Int64) -> Bool {
        [54, 55, 56, 58, 59, 60, 61, 62].contains(code)
    }

    private func stopRecording(cancelled: Bool) {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        recording = false
        if cancelled {
            recordHint = "Click Change hotkey, then hold your new shortcut."
        }
    }

    private func saveKey() {
        let trimmed = pastedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        config.openaiAPIKey = trimmed
        do {
            try config.save()
            pastedKey = ""
            config = VocalisConfig.load()
            state.keyConfigured = config.hasAPIKey
            state.statusMessage = "Key saved."
            onSavedKey()
        } catch {
            state.statusMessage = "Could not save key."
        }
    }
}

// MARK: - Permissions / Setup

struct OnboardingView: View {
    @ObservedObject var permissions: PermissionsModel
    var hotkeyLabel: String
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Vocalis Setup")
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Text("Allow Microphone, Accessibility, and Input Monitoring so hold-to-talk can record and paste.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Current hotkey: \(hotkeyLabel)")
                .font(.system(size: 13, weight: .medium))

            VStack(alignment: .leading, spacing: 12) {
                PermissionRow(
                    title: "Microphone",
                    granted: permissions.snapshot.microphone,
                    enableTitle: "Enable Microphone",
                    openTitle: "Open Mic Settings",
                    onEnable: { Task { await permissions.requestMicrophone() } },
                    onOpenSettings: { permissions.openMicrophoneSettings() }
                )
                PermissionRow(
                    title: "Accessibility",
                    granted: permissions.snapshot.accessibility,
                    enableTitle: "Enable Accessibility",
                    openTitle: "Open Accessibility Settings",
                    onEnable: { permissions.openAccessibilitySettings(promptSystem: true) },
                    onOpenSettings: { permissions.openAccessibilitySettings(promptSystem: false) }
                )
                PermissionRow(
                    title: "Input Monitoring",
                    detail: "Enable Vocalis in System Settings → Input Monitoring, then press any key to verify",
                    granted: permissions.snapshot.inputMonitoring,
                    enableTitle: "Enable Input Monitoring",
                    openTitle: "Open Input Monitoring Settings",
                    onEnable: { permissions.openInputMonitoringSettings(request: true) },
                    onOpenSettings: { permissions.openInputMonitoringSettings(request: false) }
                )
            }

            if !permissions.hotkeyStatusMessage.isEmpty {
                Text(permissions.hotkeyStatusMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
            HStack {
                Button("Refresh status") { permissions.refresh() }
                Spacer()
                Button("Done") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460, height: 500)
        .onAppear { permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }
}

struct PermissionRow: View {
    var title: String
    var detail: String? = nil
    var granted: Bool
    var enableTitle: String
    var openTitle: String
    var onEnable: () -> Void
    var onOpenSettings: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(granted ? "Granted" : "Not granted — try again")
                    .font(.system(size: 12))
                    .foregroundStyle(granted ? Color.green : Color.orange)
                if let detail, !granted {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if granted {
                Button(openTitle, action: onOpenSettings).controlSize(.small)
            } else {
                Button(enableTitle, action: onEnable)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
