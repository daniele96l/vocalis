import Foundation

@MainActor
public final class DictationController {
    public let bubble = BubbleOverlayController()
    public let recorder = AudioRecorder()
    public private(set) var config: VocalisConfig
    public private(set) var hotkey: HotkeyMonitor
    private var processing = false
    private var errorHideTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?

    public var isHotkeyTapInstalled: Bool { hotkey.isTapInstalled }
    public var hotkeyStartError: String? { hotkey.lastStartError }
    public var currentBinding: HotkeyBinding { HotkeyBinding.parse(config.hotkey) }

    public init(config: VocalisConfig = .load()) {
        self.config = config
        let binding = HotkeyBinding.parse(config.hotkey)
        self.hotkey = HotkeyMonitor(binding: binding)
        recorder.preferredDeviceUID = config.inputDeviceID
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
        recorder.preferredDeviceUID = config.inputDeviceID
        applyBinding(HotkeyBinding.parse(config.hotkey))
    }

    public func setHotkey(_ binding: HotkeyBinding) throws {
        config.hotkey = binding.configValue
        try config.save()
        applyBinding(binding)
    }

    public func setInputDevice(uid: String) throws {
        config.inputDeviceID = uid
        try config.save()
        recorder.preferredDeviceUID = uid
        _ = MicDevices.setDefaultInput(uid: uid)
    }

    public func setSTTModel(_ model: String) throws {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        config.sttModel = trimmed.isEmpty ? VocalisConfig.defaultSTTModel : trimmed
        try config.save()
    }

    public func setCleanupModel(_ model: String) throws {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        config.cleanupModel = trimmed.isEmpty ? ModelCatalog.cleanupOff : trimmed
        try config.save()
    }

    private func applyBinding(_ binding: HotkeyBinding) {
        hotkey.updateBinding(binding)
    }

    public func start() {
        hotkey.start()
    }

    public func stop() {
        stopMeter()
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
                recorder.preferredDeviceUID = config.inputDeviceID
                // Show bubble immediately so AirPods settle delay still feels responsive.
                bubble.show(.listening)
                bubble.updateMeter(
                    level: 0,
                    micName: MicDevices.displayName(forUID: config.inputDeviceID)
                )
                try await recorder.start()
                bubble.updateMeter(level: 0, micName: recorder.activeDeviceName)
                startMeter()
            } catch {
                showError(shortError(error))
            }
        }
    }

    private func endHold() {
        stopMeter()
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
                let text: String
                if ModelCatalog.isCleanupEnabled(config.cleanupModel) {
                    text = try await client.cleanup(text: transcript.text).text
                } else {
                    text = transcript.text
                }
                try Paster.paste(text)
                try? await Task.sleep(nanoseconds: 180_000_000)
                bubble.hide()
            } catch {
                showError(shortError(error))
            }
        }
    }

    private func startMeter() {
        stopMeter()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let level = self.recorder.currentLevel()
                let name = self.recorder.activeDeviceName
                self.bubble.updateMeter(level: level, micName: name)
                try? await Task.sleep(nanoseconds: 40_000_000) // ~25 fps
            }
        }
    }

    private func stopMeter() {
        meterTask?.cancel()
        meterTask = nil
    }

    private func showError(_ message: String) {
        stopMeter()
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
