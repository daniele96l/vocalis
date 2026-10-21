import Foundation

@MainActor
public final class DictationController {
    public let bubble = BubbleOverlayController()
    public let recorder = AudioRecorder()
    public private(set) var config: VocalisConfig
    public private(set) var hotkey: HotkeyMonitor
    private var processing = false
    private var errorHideTask: Task<Void, Never>?

    public var isHotkeyTapInstalled: Bool { hotkey.isTapInstalled }
    public var hotkeyStartError: String? { hotkey.lastStartError }
    public var currentBinding: HotkeyBinding { HotkeyBinding.parse(config.hotkey) }

    public init(config: VocalisConfig = .load()) {
        self.config = config
        let binding = HotkeyBinding.parse(config.hotkey)
        self.hotkey = HotkeyMonitor(binding: binding)
        hotkey.onPushBegan = { [weak self] in
            Task { @MainActor in self?.beginHold() }
        }
        hotkey.onPushEnded = { [weak self] in
            Task { @MainActor in self?.endHold() }
        }
    }

    public func retryHotkeyTap() {
        hotkey.start()
    }

    public func reloadConfig() {
        config = .load()
        applyBinding(HotkeyBinding.parse(config.hotkey))
    }

    public func setHotkey(_ binding: HotkeyBinding) throws {
        config.hotkey = binding.configValue
        try config.save()
        applyBinding(binding)
    }

    private func applyBinding(_ binding: HotkeyBinding) {
        hotkey.updateBinding(binding)
    }

    public func start() {
        hotkey.start()
    }

    public func stop() {
        hotkey.stop()
        recorder.cancel()
        bubble.hide()
    }

    private func beginHold() {
        guard !processing else { return }
        errorHideTask?.cancel()
        Task {
            let granted = await recorder.requestPermission()
            guard granted else {
                showError("No mic")
                return
            }
            do {
                try recorder.start()
                bubble.show(.listening)
            } catch {
                showError(shortError(error))
            }
        }
    }

    private func endHold() {
        guard recorder.isRecording else { return }
        processing = true
        bubble.show(.fixing)

        Task {
            defer { processing = false }
            do {
                let audioURL = try recorder.stop()
                defer { try? FileManager.default.removeItem(at: audioURL) }

                guard config.hasAPIKey else {
                    showError("Bad key")
                    return
                }

                let client = OpenAIClient(config: config)
                let transcript = try await client.transcribe(audioURL: audioURL)
                let cleaned = try await client.cleanup(text: transcript.text)
                try Paster.paste(cleaned.text)
                try? await Task.sleep(nanoseconds: 180_000_000)
                bubble.hide()
            } catch {
                showError(shortError(error))
            }
        }
    }

    private func showError(_ message: String) {
        bubble.show(.error(message))
        errorHideTask?.cancel()
        errorHideTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled {
                bubble.hide()
            }
        }
    }

    private func shortError(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return String(localized.prefix(28))
        }
        return "Failed"
    }
}
