import Foundation

public struct DictationDebugEvent: Sendable {
    public enum Status: Sendable {
        case running
        case ok
        case fail
    }

    public let label: String
    public let detail: String
    public let status: Status

    public init(label: String, detail: String, status: Status) {
        self.label = label
        self.detail = detail
        self.status = status
    }
}

public struct DictationDebugResult: Sendable {
    public let rawTranscript: String
    public let finalText: String
    public let audioBytes: Int
}

@MainActor
public final class DictationController {
    public let bubble = BubbleOverlayController()
    public let recorder = AudioRecorder()
    public private(set) var config: VocalisConfig
    public private(set) var hotkey: HotkeyMonitor
    private var processing = false
    private var starting = false
    private var debugActive = false
    private var errorHideTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?
    private var holdTask: Task<Void, Never>?
    private var liveTranscriber: LiveTranscriber?
    private var debugLevelHandler: ((Float, String) -> Void)?

    public var isDebugCapturing: Bool { debugActive && recorder.isRecording }

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

    public func setCleanupStyle(_ style: CleanupStyle) throws {
        config.cleanupStyle = style.rawValue
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
        guard !debugActive else { return }
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
        if debugActive { return }
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

                // Pick up Account changes (license / keys) without requiring an app restart.
                reloadConfig()

                guard config.hasTranscriptionKey else {
                    try? FileManager.default.removeItem(at: audioURL)
                    showError(
                        config.usesGrokSTT
                            ? "No xAI key or license"
                            : "No API key or license"
                    )
                    return
                }
                // Cleanup needs OpenAI (or the license proxy) — not a local key when licensed.
                if ModelCatalog.isCleanupEnabled(config.cleanupModel),
                   !config.usesLicense,
                   !config.hasOpenAIKey {
                    try? FileManager.default.removeItem(at: audioURL)
                    showError("No OpenAI key or license")
                    return
                }

                let client = OpenAIClient(config: config)
                let transcriptText: String
                if let live {
                    // Keep a copy for one-shot fallback if live chunks all come back empty
                    // (e.g. license proxy briefly failed while the meter still looked fine).
                    let fallbackURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("vocalis-fallback-\(UUID().uuidString).wav")
                    try? FileManager.default.copyItem(at: audioURL, to: fallbackURL)
                    defer { try? FileManager.default.removeItem(at: fallbackURL) }

                    // LiveTranscriber owns deletion of each chunk URL (including this final one).
                    live.submit(url: audioURL)
                    var joined = try await live.finishJoined()
                    if joined.isEmpty {
                        NSLog("Vocalis: live STT empty — retrying one-shot transcription")
                        joined = try await client.transcribe(audioURL: fallbackURL).text
                    }
                    if joined.isEmpty {
                        throw OpenAIClientError.emptyTranscript
                    }
                    transcriptText = joined
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

    private func detailError(_ error: Error) -> String {
        if let client = error as? OpenAIClientError {
            switch client {
            case .http(let code, let body):
                let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return "HTTP \(code)" }
                return "HTTP \(code): \(String(trimmed.prefix(240)))"
            case .missingKey, .emptyAudio, .emptyTranscript, .decode:
                return client.errorDescription ?? "Failed"
            }
        }
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        return String(describing: error)
    }

    // MARK: - Debug probe (Settings → Debug)

    /// One-shot capture for the Debug tab — no live chunking, no paste.
    public func startDebugCapture(
        onEvent: @escaping @MainActor (DictationDebugEvent) -> Void,
        onLevel: @escaping @MainActor (Float, String) -> Void
    ) async {
        guard !debugActive, !processing, !recorder.isRecording else {
            onEvent(.init(label: "Busy", detail: "Finish the current dictation first.", status: .fail))
            return
        }

        debugActive = true
        debugLevelHandler = onLevel
        reloadConfig()

        let auth = config.usesLicense ? "license → \(config.resolvedLicenseProxyURL)" : "own keys"
        onEvent(.init(
            label: "Config",
            detail: "\(auth) · STT \(config.sttModel) · cleanup \(config.cleanupModel)/\(config.resolvedCleanupStyle.rawValue)",
            status: .ok
        ))

        if !recorder.hasMicPermission {
            onEvent(.init(label: "Microphone", detail: "Requesting permission…", status: .running))
            let granted = await recorder.requestPermission()
            guard granted else {
                onEvent(.init(label: "Microphone", detail: "Permission denied", status: .fail))
                debugActive = false
                debugLevelHandler = nil
                return
            }
        }
        onEvent(.init(label: "Microphone", detail: "Permission OK", status: .ok))

        guard config.hasTranscriptionKey else {
            onEvent(.init(
                label: "Auth",
                detail: config.usesGrokSTT ? "Need xAI key or license" : "Need OpenAI key or license",
                status: .fail
            ))
            debugActive = false
            debugLevelHandler = nil
            return
        }
        onEvent(.init(
            label: "Auth",
            detail: config.usesLicense ? "License ready" : (config.usesGrokSTT ? "xAI key ready" : "OpenAI key ready"),
            status: .ok
        ))

        do {
            recorder.onChunkSealed = nil
            recorder.chunkSeconds = 0
            recorder.preferredDeviceUID = config.inputDeviceID
            onEvent(.init(label: "Record", detail: "Starting…", status: .running))
            try await recorder.start()
            let mic = recorder.activeDeviceName
            onEvent(.init(label: "Record", detail: "Listening on \(mic.isEmpty ? "default input" : mic)", status: .ok))
            startDebugMeter()
        } catch {
            onEvent(.init(label: "Record", detail: detailError(error), status: .fail))
            debugActive = false
            debugLevelHandler = nil
        }
    }

    public func cancelDebugCapture() {
        guard debugActive else { return }
        stopMeter()
        debugLevelHandler = nil
        if recorder.isRecording {
            recorder.cancel()
        }
        debugActive = false
    }

    public func finishDebugCapture(
        onEvent: @escaping @MainActor (DictationDebugEvent) -> Void
    ) async -> DictationDebugResult {
        stopMeter()
        debugLevelHandler = nil

        guard debugActive, recorder.isRecording else {
            debugActive = false
            onEvent(.init(label: "Record", detail: "Not recording", status: .fail))
            return DictationDebugResult(rawTranscript: "", finalText: "", audioBytes: 0)
        }

        processing = true
        defer {
            processing = false
            debugActive = false
        }

        do {
            let audioURL = try recorder.stop()
            defer { try? FileManager.default.removeItem(at: audioURL) }

            let bytes: Int = {
                let n = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? NSNumber)?.intValue
                return n ?? 0
            }()
            onEvent(.init(
                label: "Audio",
                detail: String(format: "%d bytes (%.1f KB)", bytes, Double(bytes) / 1024),
                status: bytes > 800 ? .ok : .fail
            ))
            if bytes <= 800 {
                onEvent(.init(label: "STT", detail: "Skipped — recording too small", status: .fail))
                return DictationDebugResult(rawTranscript: "", finalText: "", audioBytes: bytes)
            }

            reloadConfig()
            let client = OpenAIClient(config: config)
            let route = config.usesLicense
                ? (config.usesGrokSTT ? "proxy /v1/stt (Grok)" : "proxy /v1/audio/transcriptions")
                : (config.usesGrokSTT ? "api.x.ai/v1/stt" : "api.openai.com transcriptions")
            onEvent(.init(label: "STT", detail: "Sending to \(route)…", status: .running))

            let transcript: TranscriptionResult
            do {
                transcript = try await client.transcribe(audioURL: audioURL)
            } catch {
                onEvent(.init(label: "STT", detail: detailError(error), status: .fail))
                return DictationDebugResult(rawTranscript: "", finalText: "", audioBytes: bytes)
            }

            let raw = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty {
                onEvent(.init(label: "STT", detail: "Empty transcript from \(transcript.model)", status: .fail))
                return DictationDebugResult(rawTranscript: "", finalText: "", audioBytes: bytes)
            }
            onEvent(.init(
                label: "STT",
                detail: "\(raw.count) chars · \(transcript.model)" + (transcript.durationSeconds > 0
                    ? String(format: " · %.1fs audio", transcript.durationSeconds)
                    : ""),
                status: .ok
            ))

            var finalText = raw
            if ModelCatalog.isCleanupEnabled(config.cleanupModel) {
                if !config.usesLicense, !config.hasOpenAIKey {
                    onEvent(.init(label: "Cleanup", detail: "Skipped — no OpenAI key", status: .fail))
                } else {
                    onEvent(.init(
                        label: "Cleanup",
                        detail: "\(config.cleanupModel) · \(config.resolvedCleanupStyle.rawValue)…",
                        status: .running
                    ))
                    do {
                        let cleaned = try await client.cleanup(text: raw)
                        finalText = cleaned.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if finalText.isEmpty { finalText = raw }
                        onEvent(.init(
                            label: "Cleanup",
                            detail: "\(finalText.count) chars · \(cleaned.model)",
                            status: .ok
                        ))
                    } catch {
                        onEvent(.init(label: "Cleanup", detail: detailError(error) + " — using raw", status: .fail))
                        finalText = raw
                    }
                }
            } else {
                onEvent(.init(label: "Cleanup", detail: "Off — using raw transcript", status: .ok))
            }

            onEvent(.init(label: "Done", detail: "Result below (not pasted)", status: .ok))
            return DictationDebugResult(rawTranscript: raw, finalText: finalText, audioBytes: bytes)
        } catch {
            onEvent(.init(label: "Audio", detail: detailError(error), status: .fail))
            return DictationDebugResult(rawTranscript: "", finalText: "", audioBytes: 0)
        }
    }

    private func startDebugMeter() {
        stopMeter()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let level = self.recorder.currentLevel()
                let name = self.recorder.activeDeviceName
                self.debugLevelHandler?(level, name)
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
        }
    }
}
