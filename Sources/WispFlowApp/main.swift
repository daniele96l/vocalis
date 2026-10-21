import AppKit
import AVFoundation
import SwiftUI
import WispFlowCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var controller: DictationController?
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.accessory)

            let controller = DictationController()
            self.controller = controller
            controller.start()

            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = item.button {
                button.image = NSImage(
                    systemSymbolName: "waveform.circle.fill",
                    accessibilityDescription: "WispFlow"
                )
                button.image?.isTemplate = true
            }

            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: "WispFlow", action: nil, keyEquivalent: ""))
            menu.addItem(.separator())

            let hotkeyTitle: String = {
                let mode = controller.config.hotkey
                return mode == "ctrlShiftSpace"
                    ? "Hotkey: Ctrl+Shift+Space (hold)"
                    : "Hotkey: Right Option (hold)"
            }()
            menu.addItem(NSMenuItem(title: hotkeyTitle, action: nil, keyEquivalent: ""))

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
            let quit = NSMenuItem(title: "Quit WispFlow", action: #selector(quit), keyEquivalent: "q")
            quit.target = self
            menu.addItem(quit)

            item.menu = menu
            statusItem = item

            maybePromptPermissions()
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
            onClose: { [weak self] in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
            }
        )
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "WispFlow Permissions"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 420, height: 320))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
    }
}

struct OnboardingView: View {
    var onRequestMic: () -> Void
    var onRequestAccessibility: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("WispFlow")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Text("Grant Microphone and Accessibility so hold-to-talk can record and paste into the focused field.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                Button("Enable Microphone") { onRequestMic() }
                Button("Enable Accessibility") { onRequestAccessibility() }
            }

            Text("Default hotkey: hold Right Option. Fallback: Ctrl+Shift+Space (set hotkey = \"ctrlShiftSpace\" in config).")
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
        .frame(width: 420, height: 320)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
