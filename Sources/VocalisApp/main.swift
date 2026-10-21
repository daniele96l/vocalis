import AppKit
import AVFoundation
import Combine
import SwiftUI
import VocalisCore

// MARK: - Theme

enum VocalisTheme {
    /// Sea-glass teal — voice/signal, not purple-AI default.
    static let accent = Color(red: 0.12, green: 0.58, blue: 0.55)
    static let accentDeep = Color(red: 0.06, green: 0.38, blue: 0.40)
    static let warm = Color(red: 0.92, green: 0.55, blue: 0.28)
    static let ok = Color(red: 0.22, green: 0.70, blue: 0.48)
    static let warn = Color(red: 0.90, green: 0.52, blue: 0.22)

    static let display = Font.system(size: 30, weight: .bold, design: .rounded)
    static let title = Font.system(size: 22, weight: .bold, design: .rounded)
    static let body = Font.system(size: 13, weight: .regular, design: .rounded)
    static let label = Font.system(size: 12, weight: .semibold, design: .rounded)
    static let caption = Font.system(size: 11, weight: .medium, design: .rounded)
}

struct AtmosphereBackground: View {
    @Environment(\.colorScheme) private var scheme
    @State private var pulse = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: scheme == .dark
                    ? [
                        Color(red: 0.07, green: 0.10, blue: 0.12),
                        Color(red: 0.05, green: 0.14, blue: 0.16),
                        Color(red: 0.08, green: 0.11, blue: 0.14),
                    ]
                    : [
                        Color(red: 0.93, green: 0.97, blue: 0.96),
                        Color(red: 0.88, green: 0.95, blue: 0.94),
                        Color(red: 0.95, green: 0.96, blue: 0.97),
                    ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(VocalisTheme.accent.opacity(scheme == .dark ? 0.18 : 0.20))
                .frame(width: 280, height: 280)
                .blur(radius: 50)
                .offset(x: 160, y: pulse ? -40 : -20)

            Circle()
                .fill(VocalisTheme.accentDeep.opacity(scheme == .dark ? 0.22 : 0.12))
                .frame(width: 220, height: 220)
                .blur(radius: 45)
                .offset(x: -140, y: pulse ? 220 : 200)

            // Soft waveform hint along the bottom
            WaveformMotif()
                .frame(height: 56)
                .opacity(scheme == .dark ? 0.35 : 0.28)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 8)
                .padding(.horizontal, 20)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 4.5).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

struct WaveformMotif: View {
    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(0..<28, id: \.self) { i in
                let t = Double(i) / 27.0
                let h = 8 + abs(sin(t * .pi * 3.2)) * 28 + (i % 3 == 0 ? 6 : 0)
                Capsule()
                    .fill(VocalisTheme.accent.opacity(0.35 + t * 0.25))
                    .frame(width: 3, height: h)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct GlassCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(scheme == .dark
                          ? Color.white.opacity(0.06)
                          : Color.white.opacity(0.72))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                scheme == .dark
                                    ? Color.white.opacity(0.08)
                                    : Color.black.opacity(0.05),
                                lineWidth: 1
                            )
                    )
            )
    }
}

struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [VocalisTheme.accent, VocalisTheme.accentDeep],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .opacity(configuration.isPressed ? 0.85 : 1)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct QuietButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(scheme == .dark ? Color.white.opacity(0.92) : VocalisTheme.accentDeep)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(scheme == .dark ? Color.white.opacity(0.12) : Color.white.opacity(0.85))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(
                                scheme == .dark ? Color.white.opacity(0.14) : VocalisTheme.accent.opacity(0.25),
                                lineWidth: 1
                            )
                    )
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case home = "Home"
    case settings = "Settings"
    case setup = "Setup"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .home: return "waveform"
        case .settings: return "slider.horizontal.3"
        case .setup: return "checkmark.shield"
        }
    }
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
                controller.bubble.show(.fixing)
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
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                    case .settings:
                        SettingsView(
                            state: state,
                            onHotkeyChanged: onHotkeyChanged,
                            onSavedKey: onSavedKey,
                            onInputDeviceChanged: onInputDeviceChanged,
                            onGoSetup: { nav.tab = .setup },
                            onGoHome: { nav.tab = .home }
                        )
                        .transition(.opacity)
                    case .setup:
                        OnboardingView(
                            permissions: permissions,
                            state: state,
                            onGoHome: { nav.tab = .home },
                            onGoSettings: { nav.tab = .settings }
                        )
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }
                .animation(.easeInOut(duration: 0.22), value: nav.tab)
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
    @Environment(\.colorScheme) private var scheme
    @Namespace private var tabNS

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        selection = tab
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 11, weight: .semibold))
                        Text(tab.rawValue)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(selection == tab ? Color.white : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background {
                        if selection == tab {
                            Capsule(style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [VocalisTheme.accent, VocalisTheme.accentDeep],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .matchedGeometryEffect(id: "tabPill", in: tabNS)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            Capsule(style: .continuous)
                .fill(scheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.05))
        )
    }
}

// MARK: - Home

struct HomeView: View {
    @ObservedObject var state: AppState
    var onGoSettings: () -> Void
    var onGoSetup: () -> Void
    var onRefresh: () -> Void
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Vocalis")
                    .font(VocalisTheme.display)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [VocalisTheme.accent, VocalisTheme.accentDeep],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 8)

                Text("Hold \(shortHotkey) to speak. Release to clean up and paste.")
                    .font(VocalisTheme.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(appeared ? 1 : 0)
            }

            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
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
                            title: state.keyConfigured ? "API key configured" : "API key missing",
                            detail: state.keyConfigured ? "Stored on this Mac only." : "Add a key in Settings."
                        )
                    }
                    .buttonStyle(.plain)

                    thinRule

                    HStack(alignment: .top) {
                        metaBlock(title: "Hotkey", value: state.hotkeyLabel)
                        Spacer(minLength: 12)
                        metaBlock(title: "Usage today", value: state.usageToday, detail: state.usageTodayDetail)
                    }

                    thinRule

                    metaBlock(title: "Microphone", value: state.micDeviceName, detail: "Change in Settings")

                    if !state.hotkeyWarning.isEmpty {
                        Text(state.hotkeyWarning)
                            .font(VocalisTheme.caption)
                            .foregroundStyle(VocalisTheme.warn)
                    }
                }
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 12)

            HStack(spacing: 10) {
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
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                appeared = true
            }
        }
    }

    private var shortHotkey: String {
        state.hotkeyLabel.replacingOccurrences(of: " (hold)", with: "")
    }

    private var thinRule: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 1)
    }

    private func metaBlock(title: String, value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.tertiary)
                .tracking(0.6)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            if let detail {
                Text(detail)
                    .font(VocalisTheme.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusLine(ok: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(ok ? VocalisTheme.ok.opacity(0.18) : VocalisTheme.warn.opacity(0.18))
                    .frame(width: 28, height: 28)
                Image(systemName: ok ? "checkmark" : "exclamationmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(ok ? VocalisTheme.ok : VocalisTheme.warn)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(detail).font(VocalisTheme.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var state: AppState
    var onHotkeyChanged: (HotkeyBinding) -> Void
    var onSavedKey: () -> Void
    var onInputDeviceChanged: (String) -> Void
    var onGoSetup: () -> Void
    var onGoHome: () -> Void

    @State private var config = VocalisConfig.load()
    @State private var pastedKey = ""
    @State private var recording = false
    @State private var recordHint = "Click Change hotkey, then hold your new shortcut."
    @State private var localMonitor: Any?
    @State private var micDevices: [MicDevice] = MicDevices.listInputs()
    @State private var selectedMicUID: String = VocalisConfig.load().inputDeviceID

    private var keyConfigured: Bool { config.hasAPIKey }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                pageHeader(
                    title: "Settings",
                    subtitle: "API key, hotkey, microphone, and usage for this Mac."
                )

                sectionLabel("Hotkey")
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(state.hotkeyLabel)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
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
                        Text("Used while you hold the hotkey. The listening bubble shows a live waveform so you can tell if this mic hears you.")
                            .font(VocalisTheme.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Picker("Input", selection: $selectedMicUID) {
                            Text("System default").tag("")
                            ForEach(micDevices) { device in
                                Text(device.name).tag(device.uid)
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

                sectionLabel("API key")
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        if keyConfigured {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.seal.fill")
                                    .foregroundStyle(VocalisTheme.ok)
                                Text("Key configured")
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                            }
                            Text("Stored only in ~/.config/vocalis on this Mac. Never shown in full.")
                                .font(VocalisTheme.body)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Paste an OpenAI API key to enable dictation.")
                                .font(VocalisTheme.body)
                                .foregroundStyle(.secondary)
                        }
                        SecureField(keyConfigured ? "Replace key (optional)" : "sk-…", text: $pastedKey)
                            .textFieldStyle(.roundedBorder)
                        Button("Save key") { saveKey() }
                            .buttonStyle(AccentButtonStyle())
                            .disabled(pastedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                sectionLabel("Usage")
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        usageRow("Today", cost: state.usageToday, detail: state.usageTodayDetail)
                        usageRow("This week", cost: state.usageWeek, detail: state.usageWeekDetail)
                        usageRow("All time", cost: state.usageTotal, detail: state.usageTotalDetail)
                        Text("Estimated locally (whisper ≈ $0.006/min, gpt-4o-mini ≈ $0.15/$0.60 per 1M in/out). Not OpenAI billing.")
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

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.tertiary)
            .tracking(0.8)
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
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
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
            state.statusMessage = "Key saved."
            onSavedKey()
        } catch {
            state.statusMessage = "Could not save key."
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

                HStack(spacing: 8) {
                    Image(systemName: "keyboard")
                        .foregroundStyle(VocalisTheme.accent)
                    Text(state.hotkeyLabel)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(VocalisTheme.accent.opacity(0.12))
                )

                if !permissions.duplicateInstallWarning.isEmpty {
                    callout(icon: "exclamationmark.triangle.fill", text: permissions.duplicateInstallWarning)
                }

                VStack(alignment: .leading, spacing: 10) {
                    PermissionRow(
                        title: "Microphone",
                        symbol: "mic.fill",
                        detail: permissions.snapshot.microphone ? nil : permissions.microphoneHelp,
                        granted: permissions.snapshot.microphone,
                        enableTitle: "Enable",
                        openTitle: "Settings",
                        onEnable: { Task { await permissions.requestMicrophone() } },
                        onOpenSettings: { permissions.openMicrophoneSettings() }
                    )
                    PermissionRow(
                        title: "Accessibility",
                        symbol: "accessibility",
                        detail: permissions.snapshot.accessibility ? nil : permissions.accessibilityHelp,
                        granted: permissions.snapshot.accessibility,
                        enableTitle: "Enable",
                        openTitle: "Settings",
                        onEnable: { permissions.openAccessibilitySettings(promptSystem: true) },
                        onOpenSettings: { permissions.openAccessibilitySettings(promptSystem: false) }
                    )
                    PermissionRow(
                        title: "Input Monitoring",
                        symbol: "keyboard.fill",
                        detail: permissions.snapshot.inputMonitoring ? nil : permissions.inputMonitoringHelp,
                        granted: permissions.snapshot.inputMonitoring,
                        enableTitle: "Enable",
                        openTitle: "Settings",
                        onEnable: { permissions.openInputMonitoringSettings(request: true) },
                        onOpenSettings: { permissions.openInputMonitoringSettings(request: false) }
                    )
                }

                if !permissions.hotkeyStatusMessage.isEmpty {
                    callout(icon: "hand.tap.fill", text: permissions.hotkeyStatusMessage)
                }

                Text(permissions.runningAppPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .textSelection(.enabled)

                if !state.keyConfigured {
                    callout(icon: "key.fill", text: "API key still missing — add it in Settings when permissions are done.")
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

    private func callout(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(VocalisTheme.warn)
                .font(.system(size: 13, weight: .semibold))
            Text(text)
                .font(VocalisTheme.caption)
                .foregroundStyle(.primary.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(VocalisTheme.warn.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(VocalisTheme.warn.opacity(0.22), lineWidth: 1)
                )
        )
    }
}

struct PermissionRow: View {
    var title: String
    var symbol: String
    var detail: String? = nil
    var granted: Bool
    var enableTitle: String
    var openTitle: String
    var onEnable: () -> Void
    var onOpenSettings: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(granted
                          ? VocalisTheme.ok.opacity(0.16)
                          : VocalisTheme.warn.opacity(0.14))
                    .frame(width: 36, height: 36)
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(granted ? VocalisTheme.ok : VocalisTheme.warn)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Text(granted ? "Granted" : "Not granted")
                    .font(VocalisTheme.caption)
                    .foregroundStyle(granted ? VocalisTheme.ok : VocalisTheme.warn)
                if let detail, !granted {
                    Text(detail)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
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
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(scheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            granted
                                ? VocalisTheme.ok.opacity(0.25)
                                : Color.primary.opacity(0.06),
                            lineWidth: 1
                        )
                )
        )
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
