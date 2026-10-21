import AppKit
import AVFoundation
import Combine
import SwiftUI
import VocalisCore

// MARK: - Theme (Notion-quiet: monochrome, motion over color)

enum VocalisTheme {
    static let accent = Color.primary
    static let ok = Color(red: 0.18, green: 0.52, blue: 0.38)
    static let warn = Color(red: 0.72, green: 0.42, blue: 0.14)
    static let border = Color.primary.opacity(0.10)
    static let fill = Color.primary.opacity(0.035)
    static let hover = Color.primary.opacity(0.045)

    static let display = Font.system(size: 30, weight: .semibold, design: .default)
    static let title = Font.system(size: 20, weight: .semibold)
    static let body = Font.system(size: 13, weight: .regular)
    static let label = Font.system(size: 12, weight: .medium)
    static let caption = Font.system(size: 11, weight: .regular)
}

enum AppVersion {
    static let fallbackMarketing = "0.1.2"

    static var marketing: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? fallbackMarketing
    }

    static var display: String { "v\(marketing)" }
}

struct AtmosphereBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            (scheme == .dark ? Color(red: 0.11, green: 0.11, blue: 0.11) : Color(red: 0.99, green: 0.99, blue: 0.985))
            // Soft vertical wash — barely there, keeps the surface from feeling flat.
            LinearGradient(
                colors: scheme == .dark
                    ? [Color.white.opacity(0.03), .clear, Color.black.opacity(0.12)]
                    : [Color.black.opacity(0.015), .clear, Color.black.opacity(0.03)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(VocalisTheme.fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
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
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed ? VocalisTheme.hover : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(VocalisTheme.border, lineWidth: 1)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

/// Drops the system focus rectangle around controls (macOS draws it even on `.plain` buttons).
struct HideFocusRing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case home = "Home"
    case ai = "AI"
    case languages = "Languages"
    case usage = "Usage"
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
                openMain(tab: .ai)
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

        let ai = NSMenuItem(title: "AI Settings…", action: #selector(showAI), keyEquivalent: ",")
        ai.target = self
        menu.addItem(ai)

        let languages = NSMenuItem(title: "Languages…", action: #selector(showLanguages), keyEquivalent: "")
        languages.target = self
        menu.addItem(languages)

        let usage = NSMenuItem(title: "Usage…", action: #selector(showUsage), keyEquivalent: "")
        usage.target = self
        menu.addItem(usage)

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
    @objc private func showAI() { openMain(tab: .ai) }
    @objc private func showLanguages() { openMain(tab: .languages) }
    @objc private func showUsage() { openMain(tab: .usage) }
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
            openMain(tab: .ai)
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
    @Published var usageTodaySplit = "Voice $0.0000 · Cleanup $0.0000"
    @Published var usageWeekSplit = "Voice $0.0000 · Cleanup $0.0000"
    @Published var usageTotalSplit = "Voice $0.0000 · Cleanup $0.0000"
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
        usageTodaySplit = report.today.splitCostLine
        usageWeekSplit = report.week.splitCostLine
        usageTotalSplit = report.total.splitCostLine
        usageTodayDetail = detail(report.today)
        usageWeekDetail = detail(report.week)
        usageTotalDetail = detail(report.total)
    }

    private func detail(_ t: UsageTotals) -> String {
        if t.requests == 0 { return "0 requests" }
        var parts: [String] = []
        if t.sttRequests > 0 {
            var voice = "\(t.sttRequests) voice"
            if t.audioSeconds > 0 {
                voice += String(format: " · %.0fs", t.audioSeconds)
            }
            parts.append(voice)
        }
        if t.cleanupRequests > 0 {
            var polish = "\(t.cleanupRequests) cleanup"
            let tok = t.promptTokens + t.completionTokens
            if tok > 0 { polish += " · \(tok) tok" }
            parts.append(polish)
        }
        if parts.isEmpty { parts.append("\(t.requests) requests") }
        return parts.joined(separator: "  ·  ")
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
                    .padding(.horizontal, 22)
                    .padding(.top, 44)
                    .padding(.bottom, 14)

                Group {
                    switch nav.tab {
                    case .home:
                        HomeView(
                            state: state,
                            onGoAI: { go(.ai) },
                            onGoUsage: { go(.usage) },
                            onGoSetup: { go(.setup) },
                            onRefresh: onRefresh
                        )
                        .transition(tabTransition)
                    case .ai:
                        AISettingsView(
                            state: state,
                            onSavedKey: onSavedKey,
                            onInputDeviceChanged: onInputDeviceChanged,
                            onModelsChanged: onModelsChanged,
                            onGoSetup: { go(.setup) },
                            onGoHome: { go(.home) }
                        )
                        .transition(tabTransition)
                    case .languages:
                        LanguagesSettingsView(
                            state: state,
                            onModelsChanged: onModelsChanged,
                            onGoHome: { go(.home) }
                        )
                        .transition(tabTransition)
                    case .usage:
                        UsageSettingsView(
                            state: state,
                            onGoHome: { go(.home) },
                            onRefresh: onRefresh
                        )
                        .transition(tabTransition)
                    case .setup:
                        OnboardingView(
                            permissions: permissions,
                            state: state,
                            onHotkeyChanged: onHotkeyChanged,
                            onGoHome: { go(.home) },
                            onGoAI: { go(.ai) }
                        )
                        .transition(tabTransition)
                    }
                }
                .animation(.spring(response: 0.38, dampingFraction: 0.88), value: nav.tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 540, height: 640)
        .onAppear { onRefresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            onRefresh()
        }
    }

    private func go(_ tab: AppTab) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            nav.tab = tab
        }
    }

    private var tabTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 6)),
            removal: .opacity
        )
    }
}

struct TabStrip: View {
    @Binding var selection: AppTab
    @Namespace private var tabNS

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        selection = tab
                    }
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 12, weight: selection == tab ? .semibold : .regular))
                        .foregroundStyle(selection == tab ? Color.primary : Color.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                        .overlay(alignment: .bottom) {
                            if selection == tab {
                                Capsule(style: .continuous)
                                    .fill(Color.primary)
                                    .frame(height: 2)
                                    .matchedGeometryEffect(id: "tab-underline", in: tabNS)
                                    .padding(.horizontal, 10)
                            }
                        }
                }
                .buttonStyle(.plain)
                // Kill the macOS keyboard focus ring — selection is the underline only.
                .focusable(false)
                .modifier(HideFocusRing())
            }
            Spacer(minLength: 0)
            Text(AppVersion.display)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
                .padding(.trailing, 2)
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
    var onGoAI: () -> Void
    var onGoUsage: () -> Void
    var onGoSetup: () -> Void
    var onRefresh: () -> Void

    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Vocalis")
                            .font(VocalisTheme.display)
                        Text("Hold \(shortHotkey) to speak. Release to clean up and paste.")
                            .font(VocalisTheme.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    HomeIdleWave()
                        .frame(width: 72, height: 28)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 4)
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                HoverRow(action: onGoSetup) {
                    statusLine(
                        ok: state.permissionsOK,
                        title: state.permissionsOK ? "Permissions ready" : "Permissions need attention",
                        detail: state.permissionsOK
                            ? "Mic, Accessibility, Input Monitoring look good."
                            : "Open Setup to finish permissions."
                    )
                }

                thinRule

                HoverRow(action: onGoAI) {
                    statusLine(
                        ok: state.keyConfigured,
                        title: state.keyConfigured ? "API keys ready" : "API key missing",
                        detail: state.keyConfigured
                            ? "OpenAI and/or xAI keys stored on this Mac."
                            : "Add OpenAI and/or xAI keys in AI."
                    )
                }

                thinRule

                HStack(alignment: .top) {
                    metaBlock(title: "Hotkey", value: state.hotkeyLabel)
                    Spacer(minLength: 12)
                    Button(action: onGoUsage) {
                        metaBlock(
                            title: "Usage today",
                            value: state.usageToday,
                            detail: state.usageTodaySplit
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .modifier(HideFocusRing())
                }
                .padding(.vertical, 12)

                Text(state.usageTodayDetail)
                    .font(VocalisTheme.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 4)

                thinRule

                metaBlock(title: "Microphone", value: state.micDeviceName, detail: "Change in Settings")
                    .padding(.vertical, 12)

                if !state.hotkeyWarning.isEmpty {
                    Text(state.hotkeyWarning)
                        .font(VocalisTheme.caption)
                        .foregroundStyle(VocalisTheme.warn)
                        .padding(.bottom, 6)
                }
            }
            .padding(.horizontal, 2)

            HStack(spacing: 8) {
                Button("AI settings") { onGoAI() }
                    .buttonStyle(AccentButtonStyle())
                Button("Usage") { onGoUsage() }
                    .buttonStyle(QuietButtonStyle())
                Button("Permissions") { onGoSetup() }
                    .buttonStyle(QuietButtonStyle())
                Spacer()
                Button("Refresh") { onRefresh() }
                    .buttonStyle(QuietButtonStyle())
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 20)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
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
            .fill(VocalisTheme.border)
            .frame(height: 1)
    }

    private func metaBlock(title: String, value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
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
        .padding(.vertical, 11)
    }
}

/// Soft hover highlight for tappable status rows.
struct HoverRow<Content: View>: View {
    var action: () -> Void
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? VocalisTheme.hover : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .modifier(HideFocusRing())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// Decorative idle waveform on Home — always gently moving.
struct HomeIdleWave: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: false)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<9, id: \.self) { i in
                    let phase = Double(i) * 0.48
                    let amp = 0.28 + 0.72 * abs(sin(t * 2.6 + phase))
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.18 + 0.35 * amp))
                        .frame(width: 3.5, height: max(4, 26 * amp))
                }
            }
        }
    }
}

// MARK: - AI Settings

struct AISettingsView: View {
    @ObservedObject var state: AppState
    var onSavedKey: () -> Void
    var onInputDeviceChanged: (String) -> Void
    var onModelsChanged: () -> Void
    var onGoSetup: () -> Void
    var onGoHome: () -> Void

    @State private var config = VocalisConfig.load()
    @State private var pastedKey = ""
    @State private var pastedXAIKey = ""
    @State private var micDevices: [MicDevice] = MicDevices.listInputs()
    @State private var selectedMicUID: String = VocalisConfig.load().inputDeviceID
    @State private var selectedSTT: String = VocalisConfig.load().sttModel
    @State private var selectedCleanup: String = VocalisConfig.load().cleanupModel
    @State private var selectedCleanupStyle: CleanupStyle = VocalisConfig.load().resolvedCleanupStyle
    @State private var streamingSTT: Bool = VocalisConfig.load().streamingSTT

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
                    title: "AI",
                    subtitle: "Keys, models, and microphone for this Mac."
                )

                settingsSectionLabel("Microphone")
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Used while you hold the hotkey. Bluetooth (AirPods) may take half a second to connect.")
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

                settingsSectionLabel("Models")
                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("You pay on release: speech-to-text, then optional cleanup. Example ~10s hold: \(exampleHoldCost)")
                            .font(VocalisTheme.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Toggle(isOn: $streamingSTT) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Speed up long dictations")
                                    .font(.system(size: 13, weight: .medium))
                                Text(
                                    streamingSTT
                                        ? "On — transcribes ~5s chunks while you hold."
                                        : "Off — one transcription after you release."
                                )
                                .font(VocalisTheme.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                        .onChange(of: streamingSTT) { enabled in
                            saveStreaming(enabled)
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
                            Text("Cleanup model")
                                .font(VocalisTheme.caption)
                                .foregroundStyle(.secondary)
                            Picker("Cleanup model", selection: $selectedCleanup) {
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

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Cleanup strength")
                                .font(VocalisTheme.caption)
                                .foregroundStyle(.secondary)
                            Picker("Cleanup strength", selection: $selectedCleanupStyle) {
                                ForEach(CleanupStyle.allCases) { style in
                                    Text("\(style.title) — \(style.detail)").tag(style)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .disabled(!ModelCatalog.isCleanupEnabled(selectedCleanup))
                            .onChange(of: selectedCleanupStyle) { newValue in
                                saveCleanupStyle(newValue)
                            }
                            Text(selectedCleanupStyle.detail)
                                .font(VocalisTheme.caption)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                settingsSectionLabel("API keys")
                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Keys stay in ~/.config/vocalis on this Mac. Grok STT needs xAI; OpenAI models and cleanup need OpenAI.")
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

                if !state.statusMessage.isEmpty {
                    Text(state.statusMessage)
                        .font(VocalisTheme.body)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Permissions…") { onGoSetup() }
                        .buttonStyle(QuietButtonStyle())
                    Spacer()
                    Button("Back to Home") { onGoHome() }
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
            selectedCleanupStyle = config.resolvedCleanupStyle
            streamingSTT = config.streamingSTT
            micDevices = MicDevices.listInputs()
            state.refresh(
                permissions: nil,
                config: config,
                tapInstalled: true,
                tapError: nil
            )
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

    private func saveCleanupStyle(_ style: CleanupStyle) {
        do {
            var next = VocalisConfig.load()
            next.cleanupStyle = style.rawValue
            try next.save()
            config = next
            selectedCleanupStyle = style
            onModelsChanged()
            state.statusMessage = "Cleanup strength: \(style.title)."
        } catch {
            state.statusMessage = "Could not save cleanup strength."
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

private func settingsSectionLabel(_ title: String) -> some View {
    Text(title)
        .font(VocalisTheme.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
}

private func usageCostRow(_ label: String, cost: String, split: String, detail: String) -> some View {
    HStack(alignment: .top) {
        Text(label)
            .font(VocalisTheme.label)
            .frame(width: 88, alignment: .leading)
            .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
            Text("\(cost) estimated")
                .font(.system(size: 13, weight: .medium))
            Text(split)
                .font(VocalisTheme.caption)
                .foregroundStyle(.secondary)
            Text(detail)
                .font(VocalisTheme.caption)
                .foregroundStyle(.tertiary)
        }
        Spacer()
    }
}

// MARK: - Languages

struct LanguagesSettingsView: View {
    @ObservedObject var state: AppState
    var onModelsChanged: () -> Void
    var onGoHome: () -> Void

    @State private var selectedLanguages: Set<String> = Set(VocalisConfig.load().languages)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                pageHeader(
                    title: "Languages",
                    subtitle: "Languages you usually speak. One pins hard; several allow switching among those only."
                )

                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(LanguageCatalog.displayNames(for: Array(selectedLanguages)))
                            .font(.system(size: 14, weight: .medium))

                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8),
                            ],
                            spacing: 8
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

                if !state.statusMessage.isEmpty {
                    Text(state.statusMessage)
                        .font(VocalisTheme.body)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Spacer()
                    Button("Back to Home") { onGoHome() }
                        .buttonStyle(AccentButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .onAppear {
            selectedLanguages = Set(VocalisConfig.load().languages)
        }
    }

    private func languageBinding(_ code: String) -> Binding<Bool> {
        Binding(
            get: { selectedLanguages.contains(code) },
            set: { enabled in
                if enabled {
                    selectedLanguages.insert(code)
                } else {
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
            selectedLanguages = Set(next.languages)
            onModelsChanged()
            state.statusMessage = "Languages: \(LanguageCatalog.displayNames(for: next.languages))"
        } catch {
            state.statusMessage = "Could not save languages."
        }
    }
}

// MARK: - Usage

struct UsageSettingsView: View {
    @ObservedObject var state: AppState
    var onGoHome: () -> Void
    var onRefresh: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                pageHeader(
                    title: "Usage",
                    subtitle: "Estimated spend on this Mac — Voice (speech-to-text) vs Cleanup (polish)."
                )

                GlassCard {
                    VStack(alignment: .leading, spacing: 14) {
                        usageCostRow(
                            "Today",
                            cost: state.usageToday,
                            split: state.usageTodaySplit,
                            detail: state.usageTodayDetail
                        )
                        Rectangle().fill(VocalisTheme.border).frame(height: 1)
                        usageCostRow(
                            "This week",
                            cost: state.usageWeek,
                            split: state.usageWeekSplit,
                            detail: state.usageWeekDetail
                        )
                        Rectangle().fill(VocalisTheme.border).frame(height: 1)
                        usageCostRow(
                            "All time",
                            cost: state.usageTotal,
                            split: state.usageTotalSplit,
                            detail: state.usageTotalDetail
                        )
                    }
                }

                Text("Local estimates only — not provider billing. Listening while you hold is free.")
                    .font(VocalisTheme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Refresh") { onRefresh() }
                        .buttonStyle(QuietButtonStyle())
                    Spacer()
                    Button("Back to Home") { onGoHome() }
                        .buttonStyle(AccentButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .onAppear { onRefresh() }
    }
}

// MARK: - Setup

struct OnboardingView: View {
    @ObservedObject var permissions: PermissionsModel
    @ObservedObject var state: AppState
    var onHotkeyChanged: (HotkeyBinding) -> Void
    var onGoHome: () -> Void
    var onGoAI: () -> Void

    @State private var recording = false
    @State private var recordHint = "Click Change hotkey, then hold your new shortcut."
    @State private var localMonitor: Any?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                pageHeader(
                    title: "Setup",
                    subtitle: "Permissions and hotkey so hold-to-talk can record and paste."
                )

                settingsSectionLabel("Hotkey")
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

                if !permissions.duplicateInstallWarning.isEmpty {
                    callout(text: permissions.duplicateInstallWarning)
                }

                settingsSectionLabel("Permissions")

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
                    callout(text: "API key still missing — add it in AI when permissions are done.")
                }

                HStack {
                    Button("Refresh") { permissions.refresh() }
                        .buttonStyle(QuietButtonStyle())
                    Spacer()
                    Button("AI settings…") {
                        stopRecording(cancelled: true)
                        onGoAI()
                    }
                    .buttonStyle(QuietButtonStyle())
                    Button(permissions.snapshot.allCriticalGranted && permissions.snapshot.inputMonitoring
                           ? "Continue"
                           : "Home") {
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
            permissions.ensureInputMonitoringRegistered()
            permissions.refresh()
        }
        .onDisappear { stopRecording(cancelled: true) }
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
