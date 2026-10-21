import AppKit
import AVFoundation
import Combine
import SwiftUI
import VocalisCore

// MARK: - Theme (Notion-simple: flat, quiet, no gradient chrome)

enum VocalisTheme {
    static let accent = Color.primary
    static let ok = Color(red: 0.15, green: 0.55, blue: 0.35)
    static let warn = Color(red: 0.75, green: 0.45, blue: 0.12)
    static let border = Color.primary.opacity(0.12)
    static let fill = Color.primary.opacity(0.04)

    static let display = Font.system(size: 28, weight: .semibold)
    static let title = Font.system(size: 20, weight: .semibold)
    static let body = Font.system(size: 13, weight: .regular)
    static let label = Font.system(size: 12, weight: .medium)
    static let caption = Font.system(size: 11, weight: .regular)
}

struct AtmosphereBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        (scheme == .dark ? Color(red: 0.12, green: 0.12, blue: 0.12) : Color(red: 1, green: 1, blue: 1))
            .ignoresSafeArea()
    }
}

struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(VocalisTheme.fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(VocalisTheme.border, lineWidth: 1)
                    )
            )
    }
}

struct AccentButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(scheme == .dark ? Color.black : Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary)
                    .opacity(configuration.isPressed ? 0.75 : 1)
            )
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(VocalisTheme.border, lineWidth: 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.clear)
                    )
            )
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case home = "Home"
    case settings = "Settings"
    case setup = "Setup"

    var id: String { rawValue }
}

final class AppNavigation: ObservableObject {
    @Published var tab: AppTab = .home
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var controller: DictationController?
    private var mainWindow: NSWindow?
    private let permissions = PermissionsModel()
    private let appState = AppState()
    private let nav = AppNavigation()

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.accessory)
            _ = VocalisConfig.load()

            let controller = DictationController()
            self.controller = controller
            permissions.setEventTapInstalledProvider { [weak controller] in
                controller?.isHotkeyTapInstalled ?? false
            }
            permissions.setHIDBackendProvider { [weak controller] in
                (controller?.hotkey.activeBackend ?? "").hasPrefix("hid")
            }
            permissions.setHotkeyRetry { [weak controller] in
                controller?.retryHotkeyTap()
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
            permissions.ensureInputMonitoringRegistered()
            controller.start()
            syncAppState()

            // Keep a strong reference; show both template icon and "V" so the extra
            // is never an invisible blank slot (color icons / empty templates vanish).
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.isVisible = true
            if let button = item.button {
                let icon = Self.menubarIcon()
                button.image = icon
                button.imagePosition = .imageLeading
                button.title = "V"
                button.font = NSFont.systemFont(ofSize: 12, weight: .bold)
                button.toolTip = "Vocalis — hold hotkey to dictate"
                button.appearsDisabled = false
            }
            statusItem = item
            // Defer menu build so the status item is attached to the bar first.
            DispatchQueue.main.async { [weak self] in
                self?.rebuildMenu()
                self?.statusItem?.isVisible = true
            }

            permissions.refresh()
            syncAppState()

            if CommandLine.arguments.contains("--settings") {
                openMain(tab: .settings)
            } else if CommandLine.arguments.contains("--permissions") {
                openMain(tab: .setup)
            } else if CommandLine.arguments.contains("--home") {
                openMain(tab: .home)
            } else if CommandLine.arguments.contains("--demo-listening") {
                openMain(tab: .home)
                controller.bubble.show(.listening)
                controller.bubble.updateMeter(
                    level: 0.55,
                    micName: MicDevices.displayName(forUID: VocalisConfig.load().inputDeviceID)
                )
                // Animate demo levels so the waveform is obvious in screenshots.
                Task { @MainActor in
                    var t = 0.0
                    while true {
                        t += 0.05
                        let level = Float(0.25 + 0.55 * abs(sin(t * 3)))
                        controller.bubble.updateMeter(
                            level: level,
                            micName: MicDevices.displayName(forUID: VocalisConfig.load().inputDeviceID)
                        )
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                }
            } else if CommandLine.arguments.contains("--demo-fixing") {
                openMain(tab: .home)
                controller.bubble.show(.transcribing)
            } else {
                openPreferredTab()
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in
            // Always re-assert the tap when coming back — taps can die while backgrounded.
            controller?.retryHotkeyTap()
            permissions.refresh()
            syncAppState()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openMain(tab: .home) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Menubar agent — closing the window must keep Vocalis (and the hotkey) alive.
        false
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

    /// Template SF Symbol — colorful AppIcon.icns disappears on dark menu bars.
    private static func menubarIcon() -> NSImage {
        let names = ["waveform.circle.fill", "waveform", "mic.fill"]
        for name in names {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: "Vocalis") {
                let sized = NSImage(size: NSSize(width: 18, height: 18))
                sized.lockFocus()
                NSGraphicsContext.current?.imageInterpolation = .high
                image.draw(
                    in: NSRect(x: 0, y: 0, width: 18, height: 18),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1
                )
                sized.unlockFocus()
                sized.isTemplate = true
                return sized
            }
        }
        // Drawn template circle so we never install a blank image.
        let img = NSImage(size: NSSize(width: 18, height: 18))
        img.lockFocus()
        NSColor.black.setStroke()
        let path = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 14, height: 14))
        path.lineWidth = 1.5
        path.stroke()
        img.unlockFocus()
        img.isTemplate = true
        return img
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

    @objc private func showHome() { openMain(tab: .home) }
    @objc private func showSettings() { openMain(tab: .settings) }
    @objc private func showPermissions() { openMain(tab: .setup) }

    @objc private func quit() {
        Task { @MainActor in
            controller?.stop()
            NSApp.terminate(nil)
        }
    }

    private func openPreferredTab() {
        permissions.refresh()
        let snap = permissions.snapshot
        if !snap.allCriticalGranted || !snap.inputMonitoring {
            openMain(tab: .setup)
        } else if !VocalisConfig.load().hasAPIKey {
            openMain(tab: .settings)
        } else {
            openMain(tab: .home)
        }
    }

    private func openMain(tab: AppTab) {
        permissions.refresh()
        MainActor.assumeIsolated { syncAppState() }
        nav.tab = tab

        if let existing = mainWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = RootView(
            nav: nav,
            state: appState,
            permissions: permissions,
            onRefresh: { [weak self] in
                guard let app = self else { return }
                Task { @MainActor in
                    if !(app.controller?.isHotkeyTapInstalled ?? false) {
                        app.controller?.retryHotkeyTap()
                    }
                    app.permissions.refresh()
                    app.syncAppState()
                }
            },
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
            onInputDeviceChanged: { [weak self] uid in
                guard let app = self else { return }
                Task { @MainActor in
                    do {
                        try app.controller?.setInputDevice(uid: uid)
                        app.appState.micDeviceName = MicDevices.displayName(forUID: uid)
                        app.appState.statusMessage = "Microphone updated."
                        app.syncAppState()
                    } catch {
                        app.appState.statusMessage = "Could not save microphone."
                    }
                }
            },
            onModelsChanged: { [weak self] in
                guard let app = self else { return }
                Task { @MainActor in
                    app.controller?.reloadConfig()
                    app.syncAppState()
                }
            }
        )

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Vocalis"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.setContentSize(NSSize(width: 500, height: 640))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = WindowCloseDelegate.shared
        WindowCloseDelegate.shared.handlers[ObjectIdentifier(window)] = { [weak self] in
            self?.mainWindow = nil
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow = window
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
    @Published var micDeviceName = MicDevices.displayName(forUID: "")
    @Published var micDeviceUID = ""

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
        micDeviceUID = config.inputDeviceID
        micDeviceName = MicDevices.displayName(forUID: config.inputDeviceID)
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

// MARK: - Root

struct RootView: View {
    @ObservedObject var nav: AppNavigation
    @ObservedObject var state: AppState
    @ObservedObject var permissions: PermissionsModel
    var onRefresh: () -> Void
    var onHotkeyChanged: (HotkeyBinding) -> Void
    var onSavedKey: () -> Void
    var onInputDeviceChanged: (String) -> Void
    var onModelsChanged: () -> Void

    var body: some View {
        ZStack {
            AtmosphereBackground()

            VStack(spacing: 0) {
                TabStrip(selection: $nav.tab)
                    .padding(.horizontal, 20)
                    .padding(.top, 44)
                    .padding(.bottom, 12)

                Group {
                    switch nav.tab {
                    case .home:
                        HomeView(
                            state: state,
                            onGoSettings: { nav.tab = .settings },
                            onGoSetup: { nav.tab = .setup },
                            onRefresh: onRefresh
                        )
                    case .settings:
                        SettingsView(
                            state: state,
                            onHotkeyChanged: onHotkeyChanged,
                            onSavedKey: onSavedKey,
                            onInputDeviceChanged: onInputDeviceChanged,
                            onModelsChanged: onModelsChanged,
                            onGoSetup: { nav.tab = .setup },
                            onGoHome: { nav.tab = .home }
                        )
                    case .setup:
                        OnboardingView(
                            permissions: permissions,
                            state: state,
                            onGoHome: { nav.tab = .home },
                            onGoSettings: { nav.tab = .settings }
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 500, height: 640)
        .onAppear { onRefresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            onRefresh()
        }
    }
}

struct TabStrip: View {
    @Binding var selection: AppTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 13, weight: selection == tab ? .semibold : .regular))
                        .foregroundStyle(selection == tab ? Color.primary : Color.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(selection == tab ? Color.primary : Color.clear)
                                .frame(height: 1.5)
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(VocalisTheme.border)
                .frame(height: 1)
        }
    }
}

// MARK: - Home

struct HomeView: View {
    @ObservedObject var state: AppState
    var onGoSettings: () -> Void
    var onGoSetup: () -> Void
    var onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Vocalis")
                    .font(VocalisTheme.display)
                Text("Hold \(shortHotkey) to speak. Release to clean up and paste.")
                    .font(VocalisTheme.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 0) {
                Button(action: onGoSetup) {
                    statusLine(
                        ok: state.permissionsOK,
                        title: state.permissionsOK ? "Permissions ready" : "Permissions need attention",
                        detail: state.permissionsOK
                            ? "Mic, Accessibility, Input Monitoring look good."
                            : "Open Setup to finish permissions."
                    )
                }
                .buttonStyle(.plain)

                thinRule

                Button(action: onGoSettings) {
                    statusLine(
                        ok: state.keyConfigured,
                        title: state.keyConfigured ? "API keys ready" : "API key missing",
                        detail: state.keyConfigured
                            ? "OpenAI and/or xAI keys stored on this Mac."
                            : "Add OpenAI and/or xAI keys in Settings."
                    )
                }
                .buttonStyle(.plain)

                thinRule

                HStack(alignment: .top) {
                    metaBlock(title: "Hotkey", value: state.hotkeyLabel)
                    Spacer(minLength: 12)
                    metaBlock(title: "Usage today", value: state.usageToday, detail: state.usageTodayDetail)
                }
                .padding(.vertical, 10)

                thinRule

                metaBlock(title: "Microphone", value: state.micDeviceName, detail: "Change in Settings")
                    .padding(.vertical, 10)

                if !state.hotkeyWarning.isEmpty {
                    Text(state.hotkeyWarning)
                        .font(VocalisTheme.caption)
                        .foregroundStyle(VocalisTheme.warn)
                        .padding(.bottom, 4)
                }
            }
            .padding(.horizontal, 2)

            HStack(spacing: 8) {
                Button("API key & hotkey") { onGoSettings() }
                    .buttonStyle(AccentButtonStyle())
                Button("Permissions") { onGoSetup() }
                    .buttonStyle(QuietButtonStyle())
                Spacer()
                Button("Refresh") { onRefresh() }
                    .buttonStyle(QuietButtonStyle())
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 20)
    }

    private var shortHotkey: String {
        state.hotkeyLabel.replacingOccurrences(of: " (hold)", with: "")
    }

    private var thinRule: some View {
        Rectangle()
            .fill(VocalisTheme.border)
            .frame(height: 1)
    }

    private func metaBlock(title: String, value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(VocalisTheme.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .medium))
            if let detail {
                Text(detail)
                    .font(VocalisTheme.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusLine(ok: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(ok ? "✓" : "!")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(ok ? VocalisTheme.ok : VocalisTheme.warn)
                .frame(width: 16, alignment: .center)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(VocalisTheme.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text("→")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var state: AppState
    var onHotkeyChanged: (HotkeyBinding) -> Void
    var onSavedKey: () -> Void
    var onInputDeviceChanged: (String) -> Void
    var onModelsChanged: () -> Void
    var onGoSetup: () -> Void
    var onGoHome: () -> Void

    @State private var config = VocalisConfig.load()
    @State private var pastedKey = ""
    @State private var pastedXAIKey = ""
    @State private var recording = false
    @State private var recordHint = "Click Change hotkey, then hold your new shortcut."
    @State private var localMonitor: Any?
    @State private var micDevices: [MicDevice] = MicDevices.listInputs()
    @State private var selectedMicUID: String = VocalisConfig.load().inputDeviceID
    @State private var selectedSTT: String = VocalisConfig.load().sttModel
    @State private var selectedCleanup: String = VocalisConfig.load().cleanupModel
    @State private var streamingSTT: Bool = VocalisConfig.load().streamingSTT
    @State private var selectedLanguages: Set<String> = Set(VocalisConfig.load().languages)

    private var exampleHoldCost: String {
        let stt = OpenAIPricing.estimateSTT(model: selectedSTT, durationSeconds: 10)
        let cleanup: Double
        if ModelCatalog.isCleanupEnabled(selectedCleanup) {
            cleanup = OpenAIPricing.estimateCleanup(
                model: selectedCleanup,
                promptTokens: 80,
                completionTokens: 40
            )
        } else {
            cleanup = 0
        }
        return String(format: "$%.4f", stt + cleanup)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                pageHeader(
                    title: "Settings",
                    subtitle: "API key, models, hotkey, microphone, and usage for this Mac."
                )

                sectionLabel("Hotkey")
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(state.hotkeyLabel)
                            .font(.system(size: 15, weight: .medium))
                        Text(recording ? "Press new shortcut… (Esc to cancel)" : recordHint)
                            .font(VocalisTheme.body)
                            .foregroundStyle(recording ? VocalisTheme.warn : Color.secondary)
                        HStack(spacing: 8) {
                            Button(recording ? "Listening…" : "Change hotkey") {
                                toggleRecording()
                            }
                            .buttonStyle(AccentButtonStyle())
                            .disabled(recording)
                            if recording {
                                Button("Cancel") { stopRecording(cancelled: true) }
                                    .buttonStyle(QuietButtonStyle())
                            }
                        }
                    }
                }

                sectionLabel("Microphone")
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Used while you hold the hotkey. The listening meter moves when this mic hears you. Bluetooth (AirPods) may take half a second to connect.")
                            .font(VocalisTheme.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Picker("Input", selection: $selectedMicUID) {
                            Text("System default").tag("")
                            ForEach(micDevices) { device in
                                Text(device.isBluetooth ? "\(device.name) (Bluetooth)" : device.name)
                                    .tag(device.uid)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .onChange(of: selectedMicUID) { newValue in
                            onInputDeviceChanged(newValue)
                            config.inputDeviceID = newValue
                            state.micDeviceUID = newValue
                            state.micDeviceName = MicDevices.displayName(forUID: newValue)
                        }

                        Text(MicDevices.displayName(forUID: selectedMicUID))
                            .font(VocalisTheme.caption)
                            .foregroundStyle(.secondary)

                        Button("Refresh mic list") {
                            micDevices = MicDevices.listInputs()
                        }
                        .buttonStyle(QuietButtonStyle())
                    }
                }

                sectionLabel("Languages")
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Languages you usually speak. Default is English + Italian so the model doesn’t jump to something else. Select one to pin hard; select several to allow switching among those only.")
                            .font(VocalisTheme.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(LanguageCatalog.displayNames(for: Array(selectedLanguages)))
                            .font(.system(size: 13, weight: .medium))

                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8),
                            ],
                            spacing: 6
                        ) {
                            ForEach(LanguageCatalog.choices) { lang in
                                Toggle(isOn: languageBinding(lang.code)) {
                                    Text(lang.name)
                                        .font(VocalisTheme.body)
                                        .lineLimit(1)
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                }

                sectionLabel("Cost & models")
                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Listening while you hold the hotkey is free — audio stays on this Mac. You pay only when you release: speech-to-text, then optional cleanup.")
                            .font(VocalisTheme.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Transcription is the expensive (and usually slowest) step. With live streaming on, Vocalis transcribes ~5s chunks while you hold so long messages mostly finish as you release. Same per-minute price — just parallel. Cleanup is a second call (Off = snappiest).")
                            .font(VocalisTheme.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Example ~10s hold with these models: \(exampleHoldCost)")
                            .font(.system(size: 13, weight: .medium))

                        VStack(alignment: .leading, spacing: 6) {
                            Toggle(isOn: $streamingSTT) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Speed up long dictations")
                                        .font(.system(size: 13, weight: .medium))
                                    Text(
                                        streamingSTT
                                            ? "On — transcribes ~5s chunks while you hold. Turn off to wait and send one request on release."
                                            : "Off — classic mode: one transcription after you release."
                                    )
                                    .font(VocalisTheme.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .toggleStyle(.switch)
                            .onChange(of: streamingSTT) { enabled in
                                saveStreaming(enabled)
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Speech-to-text")
                                .font(VocalisTheme.caption)
                                .foregroundStyle(.secondary)
                            Picker("STT", selection: $selectedSTT) {
                                ForEach(ModelCatalog.sttChoices) { choice in
                                    Text("\(choice.title) — \(choice.detail)").tag(choice.rawValue)
                                }
                                if !ModelCatalog.sttChoices.contains(where: { $0.rawValue == selectedSTT }) {
                                    Text("\(selectedSTT) (custom)").tag(selectedSTT)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .onChange(of: selectedSTT) { newValue in
                                saveSTT(newValue)
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Cleanup")
                                .font(VocalisTheme.caption)
                                .foregroundStyle(.secondary)
                            Picker("Cleanup", selection: $selectedCleanup) {
                                ForEach(ModelCatalog.cleanupChoices) { choice in
                                    Text("\(choice.title) — \(choice.detail)").tag(choice.rawValue)
                                }
                                if !ModelCatalog.cleanupChoices.contains(where: { $0.rawValue == selectedCleanup }) {
                                    Text("\(selectedCleanup) (custom)").tag(selectedCleanup)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .onChange(of: selectedCleanup) { newValue in
                                saveCleanup(newValue)
                            }
                        }
                    }
                }

                sectionLabel("API keys")
                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Keys stay in ~/.config/vocalis on this Mac. Grok STT needs an xAI key; OpenAI models and cleanup need an OpenAI key.")
                            .font(VocalisTheme.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Image(systemName: config.hasOpenAIKey ? "checkmark.seal.fill" : "key")
                                    .foregroundStyle(config.hasOpenAIKey ? VocalisTheme.ok : .secondary)
                                Text("OpenAI")
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                                Text(config.hasOpenAIKey ? "Saved" : "Missing")
                                    .font(VocalisTheme.caption)
                                    .foregroundStyle(.secondary)
                            }
                            SecureField(config.hasOpenAIKey ? "Replace OpenAI key…" : "sk-…", text: $pastedKey)
                                .textFieldStyle(.roundedBorder)
                            Button("Save OpenAI key") { saveKey() }
                                .buttonStyle(AccentButtonStyle())
                                .disabled(pastedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Image(systemName: config.hasXAIKey ? "checkmark.seal.fill" : "key")
                                    .foregroundStyle(config.hasXAIKey ? VocalisTheme.ok : .secondary)
                                Text("xAI (Grok)")
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                                Text(config.hasXAIKey ? "Saved" : "Missing")
                                    .font(VocalisTheme.caption)
                                    .foregroundStyle(.secondary)
                            }
                            SecureField(config.hasXAIKey ? "Replace xAI key…" : "xai-…", text: $pastedXAIKey)
                                .textFieldStyle(.roundedBorder)
                            Button("Save xAI key") { saveXAIKey() }
                                .buttonStyle(AccentButtonStyle())
                                .disabled(pastedXAIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }

                sectionLabel("Usage")
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        usageRow("Today", cost: state.usageToday, detail: state.usageTodayDetail)
                        usageRow("This week", cost: state.usageWeek, detail: state.usageWeekDetail)
                        usageRow("All time", cost: state.usageTotal, detail: state.usageTotalDetail)
                        Text("Local estimates (Grok ≈ $0.10/hr; OpenAI STT ≈ $0.18–$0.36/hr; cleanup is token-priced). Not provider billing.")
                            .font(VocalisTheme.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !state.statusMessage.isEmpty {
                    Text(state.statusMessage)
                        .font(VocalisTheme.body)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Permissions…") { onGoSetup() }
                        .buttonStyle(QuietButtonStyle())
                    Spacer()
                    Button("Back to Home") {
                        stopRecording(cancelled: true)
                        onGoHome()
                    }
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .onAppear {
            config = VocalisConfig.load()
            selectedMicUID = config.inputDeviceID
            selectedSTT = config.sttModel
            selectedCleanup = ModelCatalog.isCleanupEnabled(config.cleanupModel)
                ? config.cleanupModel
                : ModelCatalog.cleanupOff
            streamingSTT = config.streamingSTT
            selectedLanguages = Set(config.languages)
            micDevices = MicDevices.listInputs()
            state.refresh(
                permissions: nil,
                config: config,
                tapInstalled: true,
                tapError: nil
            )
        }
        .onDisappear { stopRecording(cancelled: true) }
    }

    private func languageBinding(_ code: String) -> Binding<Bool> {
        Binding(
            get: { selectedLanguages.contains(code) },
            set: { enabled in
                if enabled {
                    selectedLanguages.insert(code)
                } else {
                    // Keep at least one language selected.
                    guard selectedLanguages.count > 1 else { return }
                    selectedLanguages.remove(code)
                }
                saveLanguages()
            }
        )
    }

    private func saveLanguages() {
        do {
            var next = VocalisConfig.load()
            next.languages = LanguageCatalog.normalize(Array(selectedLanguages))
            try next.save()
            config = next
            selectedLanguages = Set(next.languages)
            onModelsChanged()
            state.statusMessage = "Languages: \(LanguageCatalog.displayNames(for: next.languages))"
        } catch {
            state.statusMessage = "Could not save languages."
        }
    }

    private func saveSTT(_ model: String) {
        do {
            var next = VocalisConfig.load()
            next.sttModel = model
            try next.save()
            config = next
            onModelsChanged()
            if ModelCatalog.isGrokSTT(model) {
                state.statusMessage = next.hasXAIKey
                    ? "Using Grok Voice Transcribe."
                    : "Grok selected — add an xAI API key below."
            } else {
                state.statusMessage = next.hasOpenAIKey
                    ? "Transcription model updated."
                    : "OpenAI model selected — add an OpenAI API key below."
            }
        } catch {
            state.statusMessage = "Could not save model."
        }
    }

    private func saveCleanup(_ model: String) {
        do {
            var next = VocalisConfig.load()
            next.cleanupModel = model
            try next.save()
            config = next
            onModelsChanged()
            state.statusMessage = model == ModelCatalog.cleanupOff
                ? "Cleanup off — raw transcript only."
                : "Cleanup model updated."
        } catch {
            state.statusMessage = "Could not save model."
        }
    }

    private func saveStreaming(_ enabled: Bool) {
        do {
            var next = VocalisConfig.load()
            next.streamingSTT = enabled
            try next.save()
            config = next
            onModelsChanged()
            state.statusMessage = enabled
                ? "Live transcription on — chunks while you hold."
                : "Live transcription off — one request on release."
        } catch {
            state.statusMessage = "Could not save setting."
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(VocalisTheme.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    private func usageRow(_ label: String, cost: String, detail: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(VocalisTheme.label)
                .frame(width: 88, alignment: .leading)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(cost) estimated")
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(VocalisTheme.caption)
                    .foregroundStyle(.secondary)
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
        if event.type == .keyDown && event.keyCode == 53 {
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
            state.statusMessage = "OpenAI key saved."
            onSavedKey()
        } catch {
            state.statusMessage = "Could not save OpenAI key."
        }
    }

    private func saveXAIKey() {
        let trimmed = pastedXAIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        config.xaiAPIKey = trimmed
        do {
            try config.save()
            pastedXAIKey = ""
            config = VocalisConfig.load()
            state.keyConfigured = config.hasAPIKey
            state.statusMessage = "xAI key saved."
            onSavedKey()
        } catch {
            state.statusMessage = "Could not save xAI key."
        }
    }
}

private func pageHeader(title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(title).font(VocalisTheme.title)
        Text(subtitle)
            .font(VocalisTheme.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Setup

struct OnboardingView: View {
    @ObservedObject var permissions: PermissionsModel
    @ObservedObject var state: AppState
    var onGoHome: () -> Void
    var onGoSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                pageHeader(
                    title: "Setup",
                    subtitle: "Allow Microphone, Accessibility, and Input Monitoring so hold-to-talk can record and paste."
                )

                Text("Hotkey: \(state.hotkeyLabel)")
                    .font(VocalisTheme.body)
                    .foregroundStyle(.secondary)

                if !permissions.duplicateInstallWarning.isEmpty {
                    callout(text: permissions.duplicateInstallWarning)
                }

                VStack(alignment: .leading, spacing: 0) {
                    PermissionRow(
                        title: "Microphone",
                        detail: permissions.snapshot.microphone ? nil : permissions.microphoneHelp,
                        granted: permissions.snapshot.microphone,
                        enableTitle: "Enable",
                        openTitle: "Settings",
                        onEnable: { Task { await permissions.requestMicrophone() } },
                        onOpenSettings: { permissions.openMicrophoneSettings() }
                    )
                    thinDivider
                    PermissionRow(
                        title: "Accessibility",
                        detail: permissions.snapshot.accessibility ? nil : permissions.accessibilityHelp,
                        granted: permissions.snapshot.accessibility,
                        enableTitle: "Enable",
                        openTitle: "Settings",
                        onEnable: { permissions.openAccessibilitySettings(promptSystem: true) },
                        onOpenSettings: { permissions.openAccessibilitySettings(promptSystem: false) }
                    )
                    thinDivider
                    PermissionRow(
                        title: "Input Monitoring",
                        detail: permissions.snapshot.inputMonitoring ? nil : permissions.inputMonitoringHelp,
                        granted: permissions.snapshot.inputMonitoring,
                        enableTitle: "Enable",
                        openTitle: "Settings",
                        onEnable: { permissions.openInputMonitoringSettings(request: true) },
                        onOpenSettings: { permissions.openInputMonitoringSettings(request: false) }
                    )
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(VocalisTheme.border, lineWidth: 1)
                )

                if !permissions.hotkeyStatusMessage.isEmpty {
                    callout(text: permissions.hotkeyStatusMessage)
                }

                Text(permissions.runningAppPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .textSelection(.enabled)

                if !state.keyConfigured {
                    callout(text: "API key still missing — add it in Settings when permissions are done.")
                }

                HStack {
                    Button("Refresh") { permissions.refresh() }
                        .buttonStyle(QuietButtonStyle())
                    Spacer()
                    Button("API key…") { onGoSettings() }
                        .buttonStyle(QuietButtonStyle())
                    Button(permissions.snapshot.allCriticalGranted && permissions.snapshot.inputMonitoring
                           ? "Continue"
                           : "Home") { onGoHome() }
                        .buttonStyle(AccentButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .onAppear {
            permissions.ensureInputMonitoringRegistered()
            permissions.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }

    private var thinDivider: some View {
        Rectangle()
            .fill(VocalisTheme.border)
            .frame(height: 1)
    }

    private func callout(text: String) -> some View {
        Text(text)
            .font(VocalisTheme.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(VocalisTheme.border, lineWidth: 1)
            )
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
        HStack(alignment: .center, spacing: 10) {
            Text(granted ? "✓" : "·")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(granted ? VocalisTheme.ok : .secondary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(granted ? "Granted" : "Not granted")
                    .font(VocalisTheme.caption)
                    .foregroundStyle(granted ? VocalisTheme.ok : VocalisTheme.warn)
                if let detail, !granted {
                    Text(detail)
                        .font(VocalisTheme.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if granted {
                Button(openTitle, action: onOpenSettings)
                    .buttonStyle(QuietButtonStyle())
                    .controlSize(.small)
            } else {
                Button(enableTitle, action: onEnable)
                    .buttonStyle(AccentButtonStyle())
                    .controlSize(.small)
            }
        }
        .padding(12)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
