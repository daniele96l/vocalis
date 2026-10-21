import Foundation

@MainActor
public final class DictationController {
    public let bubble = BubbleOverlayController()
    public let recorder = AudioRecorder()
    public private(set) var config: VocalisConfig
    public private(set) var hotkey: HotkeyMonitor
    private var processing = false
    private var starting = false
    private var errorHideTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?
    private var holdTask: Task<Void, Never>?
    private var liveTranscriber: LiveTranscriber?

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
        recorder.prewarm()
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
        recorder.prewarm()
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

    public func setStreamingSTT(_ enabled: Bool) throws {
        config.streamingSTT = enabled
        try config.save()
    }

    public func setLanguages(_ codes: [String]) throws {
        config.languages = LanguageCatalog.normalize(codes)
        try config.save()
    }

    private func applyBinding(_ binding: HotkeyBinding) {
        hotkey.updateBinding(binding)
    }

    public func start() {
        hotkey.start()
        recorder.prewarm()
    }

    public func stop() {
        holdTask?.cancel()
        holdTask = nil
        starting = false
        liveTranscriber?.cancel()
        liveTranscriber = nil
        stopMeter()
        hotkey.stop()
        recorder.releaseHardware()
        bubble.hide()
    }

    private func beginHold() {
        guard !processing else { return }
        errorHideTask?.cancel()
        holdTask?.cancel()
        liveTranscriber?.cancel()
        liveTranscriber = nil

        bubble.show(.listening)
        bubble.updateMeter(
            level: 0,
            micName: MicDevices.displayName(forUID: config.inputDeviceID)
        )
        starting = true
        recorder.preferredDeviceUID = config.inputDeviceID

        holdTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.starting = false }

            if !self.recorder.hasMicPermission {
                let granted = await self.recorder.requestPermission()
                guard granted else {
                    self.showError("No mic")
                    return
                }
            }
            guard !Task.isCancelled else { return }

            do {
                if self.config.streamingSTT, self.config.hasTranscriptionKey {
                    let live = LiveTranscriber(client: OpenAIClient(config: self.config))
                    self.liveTranscriber = live
                    self.recorder.chunkSeconds = LiveTranscriber.defaultChunkSeconds
                    self.recorder.onChunkSealed = { [weak live] url in
                        live?.submit(url: url)
                    }
                } else {
                    self.recorder.onChunkSealed = nil
                    self.recorder.chunkSeconds = 0
                }

                try await self.recorder.start()
                guard !Task.isCancelled else {
                    self.recorder.cancel()
                    self.liveTranscriber?.cancel()
                    self.liveTranscriber = nil
                    return
                }
                self.bubble.updateMeter(level: 0, micName: self.recorder.activeDeviceName)
                self.startMeter()
            } catch {
                guard !Task.isCancelled else { return }
                self.liveTranscriber?.cancel()
                self.liveTranscriber = nil
                self.showError(self.shortError(error))
            }
        }
    }

    private func endHold() {
        stopMeter()
        holdTask?.cancel()
        holdTask = nil

        guard recorder.isRecording else {
            starting = false
            liveTranscriber?.cancel()
            liveTranscriber = nil
            if !processing {
                bubble.hide()
            }
            return
        }

        processing = true
        let live = liveTranscriber
        liveTranscriber = nil
        recorder.onChunkSealed = nil

        let pending = live?.pendingCount ?? 0
        bubble.show(.transcribing)
        if pending > 0 {
            NSLog("Vocalis: finishing with \(pending) live STT chunk(s) already in flight")
        }

        Task {
            defer {
                processing = false
                live?.cancel()
            }
            do {
                let audioURL = try recorder.stop()

                guard config.hasTranscriptionKey else {
                    try? FileManager.default.removeItem(at: audioURL)
                    showError(config.usesGrokSTT ? "No xAI key" : "Bad key")
                    return
                }
                if ModelCatalog.isCleanupEnabled(config.cleanupModel), !config.hasOpenAIKey {
                    try? FileManager.default.removeItem(at: audioURL)
                    showError("No OpenAI key")
                    return
                }

                let client = OpenAIClient(config: config)
                let transcriptText: String
                if let live {
                    // LiveTranscriber owns deletion of each chunk URL (including this final one).
                    live.submit(url: audioURL)
                    transcriptText = try await live.finishJoined()
                    if transcriptText.isEmpty {
                        throw OpenAIClientError.emptyTranscript
                    }
                } else {
                    defer { try? FileManager.default.removeItem(at: audioURL) }
                    transcriptText = try await client.transcribe(audioURL: audioURL).text
                }

                let text: String
                if ModelCatalog.isCleanupEnabled(config.cleanupModel) {
                    bubble.show(.polishing)
                    text = try await client.cleanup(text: transcriptText).text
                } else {
                    text = transcriptText
                }

                // Archive + clipboard always succeed before ⌘V — never lose the words.
                let result = try Paster.deliver(
                    text,
                    archiveNote: ModelCatalog.isCleanupEnabled(config.cleanupModel) ? "cleaned" : "raw"
                )
                switch result {
                case .pasted:
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    bubble.hide()
                case .clipboardOnly:
                    showNotice("On clipboard · ⌘V", seconds: 3.2)
                }
            } catch {
                // If we already have transcript text in a nested failure, it's archived by deliver.
                // For earlier failures, surface the error only.
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
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
        }
    }

    private func stopMeter() {
        meterTask?.cancel()
        meterTask = nil
    }

    private func showError(_ message: String) {
        showNotice(message, seconds: 2.0)
    }

    private func showNotice(_ message: String, seconds: Double) {
        stopMeter()
        bubble.show(.error(message))
        errorHideTask?.cancel()
        errorHideTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
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
