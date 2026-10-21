import AppKit
import AVFoundation
import SwiftUI
import VocalisCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var controller: DictationController?
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.accessory)

            // Bootstrap key from env / local .env files into ~/.config/vocalis (no prompts).
            _ = VocalisConfig.load()

            let controller = DictationController()
            self.controller = controller
            controller.start()

            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = item.button {
                button.image = NSImage(
                    systemSymbolName: "waveform.circle.fill",
                    accessibilityDescription: "Vocalis"
                )
                button.image?.isTemplate = true
            }

            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: "Vocalis", action: nil, keyEquivalent: ""))
            menu.addItem(.separator())

            let hotkeyTitle: String = {
                let mode = controller.config.hotkey
                return mode == "ctrlShiftSpace"
                    ? "Hotkey: Ctrl+Shift+Space (hold)"
                    : "Hotkey: Right Option (hold)"
            }()
            menu.addItem(NSMenuItem(title: hotkeyTitle, action: nil, keyEquivalent: ""))

            let settings = NSMenuItem(
                title: "Settings…",
                action: #selector(showSettings),
                keyEquivalent: ","
            )
            settings.target = self
            menu.addItem(settings)

            let perm = NSMenuItem(
                title: "Permissions…",
                action: #selector(showPermissions),
                keyEquivalent: ""
            )
            perm.target = self
            menu.addItem(perm)

            let reload = NSMenuItem(
                title: "Reload Config",
                action: #selector(reloadConfig),
                keyEquivalent: "r"
            )
            reload.target = self
            menu.addItem(reload)

            menu.addItem(.separator())
            let quit = NSMenuItem(title: "Quit Vocalis", action: #selector(quit), keyEquivalent: "q")
            quit.target = self
            menu.addItem(quit)

            item.menu = menu
            statusItem = item

            maybePromptPermissions()
            maybePromptForMissingKey()
        }
    }

    @objc private func reloadConfig() {
        Task { @MainActor in
            controller?.reloadConfig()
        }
    }

    @objc private func showPermissions() {
        openOnboarding()
    }

    @objc private func showSettings() {
        openSettings()
    }

    @objc private func quit() {
        Task { @MainActor in
            controller?.stop()
            NSApp.terminate(nil)
        }
    }

    private func maybePromptPermissions() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let ax = Paster.isAccessibilityTrusted(prompt: false)
        if mic != .authorized || !ax {
            openOnboarding()
        }
    }

    private func maybePromptForMissingKey() {
        let config = VocalisConfig.load()
        if !config.hasAPIKey {
            openSettings()
        }
    }

    private func openOnboarding() {
        if let existing = onboardingWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = OnboardingView(
            onRequestMic: {
                Task {
                    _ = await AVCaptureDevice.requestAccess(for: .audio)
                }
            },
            onRequestAccessibility: {
                _ = Paster.isAccessibilityTrusted(prompt: true)
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            },
            onRequestInputMonitoring: {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                    NSWorkspace.shared.open(url)
                }
            },
            onClose: { [weak self] in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
            }
        )
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Vocalis Setup"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 440, height: 360))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
    }

    private func openSettings() {
        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SettingsView(
            onSaved: { [weak self] in
                let controller = self?.controller
                Task { @MainActor in
                    controller?.reloadConfig()
                }
            },
            onClose: { [weak self] in
                self?.settingsWindow?.close()
                self?.settingsWindow = nil
            }
        )
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Vocalis Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 440, height: 280))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }
}

struct OnboardingView: View {
    var onRequestMic: () -> Void
    var onRequestAccessibility: () -> Void
    var onRequestInputMonitoring: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Vocalis")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Text("One-time setup: allow Microphone and Accessibility so hold-to-talk can record and paste into the focused field.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                Button("Enable Microphone") { onRequestMic() }
                Button("Enable Accessibility") { onRequestAccessibility() }
                Button("Enable Input Monitoring (if hotkey fails)") { onRequestInputMonitoring() }
            }

            Text("Hold Right Option to dictate. Release to clean up and paste.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
            HStack {
                Spacer()
                Button("Done") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440, height: 360)
    }
}

struct SettingsView: View {
    var onSaved: () -> Void
    var onClose: () -> Void

    @State private var config = VocalisConfig.load()
    @State private var pastedKey = ""
    @State private var statusMessage = ""

    private var keyConfigured: Bool { config.hasAPIKey }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.system(size: 22, weight: .bold, design: .rounded))

            Group {
                if keyConfigured {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text("Key configured")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    Text("Vocalis will use your saved OpenAI key. Paste a new key below only to replace it.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Paste your OpenAI API key to enable dictation. It is stored only in ~/.config/vocalis/config.toml on this Mac.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SecureField(keyConfigured ? "Replace key (optional)" : "sk-…", text: $pastedKey)
                .textFieldStyle(.roundedBorder)

            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            HStack {
                Button("Open Permissions…") {
                    // Soft handoff: close settings; user can reopen Permissions from menu
                    onClose()
                }
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(pastedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !keyConfigured)
                Button("Done") { onClose() }
            }
        }
        .padding(24)
        .frame(width: 440, height: 280)
        .onAppear {
            config = VocalisConfig.load()
        }
    }

    private func save() {
        let trimmed = pastedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            config.openaiAPIKey = trimmed
        }
        do {
            try config.save()
            statusMessage = "Saved."
            pastedKey = ""
            config = VocalisConfig.load()
            onSaved()
        } catch {
            statusMessage = "Could not save."
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
