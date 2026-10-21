import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

public enum AudioRecorderError: LocalizedError {
    case permissionDenied
    case setupFailed(String)
    case notRecording

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: return "No mic"
        case .setupFailed(let msg): return msg
        case .notRecording: return "Not recording"
        }
    }
}

/// Captures mic audio for Whisper.
/// Non-Bluetooth: AVAudioEngine on the system/default route (no CurrentDevice bind).
/// Bluetooth (AirPods): AudioQueue — binding CurrentDevice on AVAudioEngine yields 0 buffers.
/// Optional chunk rotation feeds live/parallel STT while the hotkey is held.
@MainActor
public final class AudioRecorder: NSObject {
    /// UID from config; empty = system default.
    public var preferredDeviceUID: String = ""
    public private(set) var activeDeviceName: String = MicDevices.displayName(forUID: "")

    /// When > 0, sealed chunk WAVs are delivered via `onChunkSealed` during recording.
    public var chunkSeconds: Double = LiveTranscriber.defaultChunkSeconds
    public var onChunkSealed: ((URL) -> Void)?

    private var engine: AVAudioEngine?
    private var audioQueue: AudioQueueRef?
    private var queueBuffers: [AudioQueueBufferRef] = []
    private var writeTarget: ChunkWriteTarget?
    private var previousOutputUID: String?
    /// Meter published from the audio thread (lock) — avoid MainActor Task-per-buffer lag.
    private let levelLock = NSLock()
    private nonisolated(unsafe) var latestLevel: Float = 0
    private nonisolated(unsafe) var bufferCount: Int = 0
    private var isBluetoothSession = false
    private var usingAudioQueue = false
    private var writeGain: Float = 1
    /// Keep AirPods HFP warm across dictations so the next hold starts instantly.
    private var keepBluetoothWarm = true
    private var chunkTask: Task<Void, Never>?
    private var silenceWatchTask: Task<Void, Never>?
    /// True after we have seen real mic energy this hold (silence restart only then).
    private nonisolated(unsafe) var sawAudibleSignal = false
    private var silenceRestarts = 0

    public var isRecording: Bool {
        if usingAudioQueue { return audioQueue != nil }
        return engine?.isRunning == true
    }

    /// Fast path when already authorized — avoids TCC round-trip on every hold.
    public var hasMicPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    public func requestPermission() async -> Bool {
        if hasMicPermission { return true }
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Call at launch / mic change so the first hold does not pay HFP switch cost.
    public func prewarm() {
        let device = MicDevices.device(uid: preferredDeviceUID)
        guard device?.isBluetooth == true else { return }
        let activation = MicDevices.activateInput(uid: preferredDeviceUID)
        if previousOutputUID == nil {
            previousOutputUID = activation.previousOutputUID
        }
        isBluetoothSession = true
        keepBluetoothWarm = true
        NSLog("Vocalis: prewarmed Bluetooth route for \(MicDevices.displayName(forUID: preferredDeviceUID))")
    }

    public func start() async throws {
        if !hasMicPermission {
            throw AudioRecorderError.permissionDenied
        }
        // Tear down capture only — keep BT route warm so we do not miss first words.
        tearDownCapture(deleteFile: true)

        let device = MicDevices.device(uid: preferredDeviceUID)
        let alreadyWarm = device?.isBluetooth == true
            && MicDevices.isBluetoothRouteWarm(uid: preferredDeviceUID)
        let activation = MicDevices.activateInput(uid: preferredDeviceUID)
        if previousOutputUID == nil {
            previousOutputUID = activation.previousOutputUID
        }
        isBluetoothSession = device?.isBluetooth == true
        keepBluetoothWarm = true
        activeDeviceName = MicDevices.displayName(forUID: preferredDeviceUID)
        writeGain = isBluetoothSession ? 6.0 : 1.0
        setLevel(0)
        setBufferCount(0)
        sawAudibleSignal = false
        silenceRestarts = 0

        // HFP/SCO needs a beat to come up; too short → first words OK then silence.
        if isBluetoothSession, activation.routeChanged || !alreadyWarm {
            try? await Task.sleep(nanoseconds: alreadyWarm ? 80_000_000 : 350_000_000)
        }

        try startCapture(device: device)
        startChunkTimerIfNeeded()
        startSilenceWatchIfNeeded()
    }

    public func stop() throws -> URL {
        guard writeTarget != nil else { throw AudioRecorderError.notRecording }
        stopChunkTimer()
        stopSilenceWatch()
        let buffers = currentBufferCount()
        let url = writeTarget?.finish()
        tearDownCapture(deleteFile: false)
        setLevel(0)
        guard let url else { throw AudioRecorderError.notRecording }
        NSLog("Vocalis: stopped after \(buffers) buffers")
        return url
    }

    public func cancel() {
        stopChunkTimer()
        stopSilenceWatch()
        tearDownCapture(deleteFile: true)
        setLevel(0)
        if !keepBluetoothWarm {
            finishBluetoothRoute()
        }
    }

    /// Restore previous output (call on app quit).
    public func releaseHardware() {
        keepBluetoothWarm = false
        stopChunkTimer()
        stopSilenceWatch()
        tearDownCapture(deleteFile: true)
        setLevel(0)
        finishBluetoothRoute()
    }

    /// Prefer engine on the already-activated default input (no CurrentDevice bind).
    /// AudioQueue is the Bluetooth fallback — also without CurrentDevice (that zeroes HFP).
    private func startCapture(device: MicDevice?) throws {
        if isBluetoothSession {
            do {
                try startEngine(device: nil) // nil → never bind CurrentDevice
                NSLog("Vocalis: Bluetooth capture via engine (default route)")
                return
            } catch {
                NSLog("Vocalis: engine failed on BT (\(error.localizedDescription)); trying AudioQueue")
                tearDownCapture(deleteFile: true)
                try startAudioQueue(device: device)
            }
        } else {
            try startEngine(device: device)
        }
    }

    public func currentLevel() -> Float {
        levelLock.lock()
        defer { levelLock.unlock() }
        return latestLevel
    }

    private func currentBufferCount() -> Int {
        levelLock.lock()
        defer { levelLock.unlock() }
        return bufferCount
    }

    private func setLevel(_ value: Float) {
        levelLock.lock()
        latestLevel = value
        levelLock.unlock()
    }

    private func setBufferCount(_ value: Int) {
        levelLock.lock()
        bufferCount = value
        levelLock.unlock()
    }

    /// Peak-hold so brief dips mid-phrase do not flash "Listening (quiet)".
    nonisolated private func publishLevel(_ instant: Float) {
        let clamped = max(0, min(1, instant))
        levelLock.lock()
        let held = max(clamped, latestLevel * 0.82)
        latestLevel = held < 0.0005 ? 0 : held
        bufferCount += 1
        if clamped >= 0.04 { sawAudibleSignal = true }
        levelLock.unlock()
    }

    // MARK: - Chunking

    private func startChunkTimerIfNeeded() {
        stopChunkTimer()
        guard chunkSeconds > 0.5, onChunkSealed != nil else { return }
        let interval = chunkSeconds
        chunkTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.sealCurrentChunkIfWorthwhile()
                }
            }
        }
    }

    private func stopChunkTimer() {
        chunkTask?.cancel()
        chunkTask = nil
    }

    /// AirPods HFP often goes silent mid-hold; restart capture once if energy dies.
    private func startSilenceWatchIfNeeded() {
        stopSilenceWatch()
        guard isBluetoothSession else { return }
        silenceWatchTask = Task { [weak self] in
            var silentTicks = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.isRecording else { return }
                    let level = self.currentLevel()
                    let heard: Bool = {
                        self.levelLock.lock()
                        defer { self.levelLock.unlock() }
                        return self.sawAudibleSignal
                    }()
                    if heard, level < 0.012 {
                        silentTicks += 1
                    } else {
                        silentTicks = 0
                    }
                    // ~0.8s of silence after we already heard speech
                    if silentTicks >= 4, self.silenceRestarts < 2 {
                        silentTicks = 0
                        self.restartCaptureAfterSilence()
                    }
                }
            }
        }
    }

    private func stopSilenceWatch() {
        silenceWatchTask?.cancel()
        silenceWatchTask = nil
    }

    private func restartCaptureAfterSilence() {
        guard writeTarget != nil else { return }
        silenceRestarts += 1
        NSLog("Vocalis: mic went silent mid-hold — restarting capture (#\(silenceRestarts))")
        // Keep the same WAV so we do not lose earlier speech.
        let existing = writeTarget
        tearDownCaptureKeepingWriter()
        writeTarget = existing
        sawAudibleSignal = false
        setLevel(0)
        do {
            _ = MicDevices.activateInput(uid: preferredDeviceUID)
            let device = MicDevices.device(uid: preferredDeviceUID)
            try startCapture(device: device)
        } catch {
            NSLog("Vocalis: silence restart failed: \(error.localizedDescription)")
            writeTarget = existing
        }
    }

    private func sealCurrentChunkIfWorthwhile() {
        guard let writeTarget, let onChunkSealed else { return }
        // Avoid sealing nearly-empty chunks (speech pause / startup).
        guard writeTarget.currentDurationSeconds() >= max(1.2, chunkSeconds * 0.35) else { return }
        do {
            let sealed = try writeTarget.rotate()
            onChunkSealed(sealed)
        } catch {
            NSLog("Vocalis: chunk rotate failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Engine (wired / built-in)

    private func startEngine(device: MicDevice?) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode

        if let device, !preferredDeviceUID.isEmpty {
            let currentDefault = MicDevices.defaultInput()?.coreAudioID
            if currentDefault != device.coreAudioID {
                try bindInputDevice(device.coreAudioID, on: input)
            }
        }

        engine.prepare()
        let hwFormat = input.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw AudioRecorderError.setupFailed("Mic format unavailable — try Built-in mic")
        }

        // Always write mono int16 WAV — Grok rejects empty/float captures; OpenAI accepts int16.
        let writeFormat = try Self.int16MonoFormat(sampleRate: hwFormat.sampleRate)
        let target: ChunkWriteTarget
        if let existing = writeTarget, abs(existing.sampleRate - writeFormat.sampleRate) < 1 {
            target = existing
        } else if writeTarget != nil {
            // Sample rate changed after HFP settle — keep going on a fresh file segment.
            NSLog("Vocalis: input rate changed (\(Int(writeTarget!.sampleRate))→\(Int(writeFormat.sampleRate))); new segment")
            target = try ChunkWriteTarget(format: writeFormat)
        } else {
            target = try ChunkWriteTarget(format: writeFormat)
        }
        let converter = AVAudioConverter(from: hwFormat, to: writeFormat)
        let gain = writeGain

        input.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, _ in
            self?.handleEngineBuffer(
                buffer,
                converter: converter,
                target: target,
                fileFormat: writeFormat,
                writeGain: gain
            )
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioRecorderError.setupFailed("Mic start failed")
        }

        self.engine = engine
        self.writeTarget = target
        self.usingAudioQueue = false
        NSLog("Vocalis: engine recording on \(activeDeviceName) @ \(Int(hwFormat.sampleRate)) Hz")
    }

    // MARK: - AudioQueue (Bluetooth / AirPods)

    private func startAudioQueue(device: MicDevice?) throws {
        // Prefer HFP-ish rate; after create we adopt whatever Core Audio actually chose.
        let rate = MicDevices.nominalSampleRate(uid: preferredDeviceUID)
        let sampleRate = (rate > 0 && rate <= 48_000) ? rate : 16_000

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        // Packed interleaved float is more widely accepted by AudioQueue input.
        asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        asbd.mBytesPerPacket = 4
        asbd.mBytesPerFrame = 4

        // Do NOT set kAudioQueueProperty_CurrentDevice — same failure mode as AVAudioEngine
        // CurrentDevice bind on AirPods (buffers go silent after a second or two).
        // Default input was already set by MicDevices.activateInput.
        _ = device

        var queue: AudioQueueRef?
        // Placeholder context; formats filled after Core Audio negotiates the real ASBD.
        let provisionalWrite = try Self.int16MonoFormat(sampleRate: sampleRate)
        guard let provisionalCapture = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw AudioRecorderError.setupFailed("Mic format failed")
        }
        let provisionalTarget = try writeTarget ?? ChunkWriteTarget(format: provisionalWrite)
        let context = QueueContext(
            owner: self,
            target: provisionalTarget,
            writeGain: writeGain,
            captureFormat: provisionalCapture,
            writeFormat: provisionalWrite,
            converter: nil
        )

        let status = AudioQueueNewInput(
            &asbd,
            { userData, aq, buffer, _, _, _ in
                guard let userData else { return }
                let ctx = Unmanaged<QueueContext>.fromOpaque(userData).takeUnretainedValue()
                ctx.handle(buffer: buffer, queue: aq)
            },
            Unmanaged.passUnretained(context).toOpaque(),
            nil,
            nil,
            0,
            &queue
        )
        guard status == noErr, let queue else {
            throw AudioRecorderError.setupFailed("Mic queue failed (\(status))")
        }

        // Adopt the format Core Audio actually negotiated (often 8/16 kHz on HFP).
        var actual = asbd
        var propSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioQueueGetProperty(queue, kAudioQueueProperty_StreamDescription, &actual, &propSize) == noErr {
            asbd = actual
        }
        let captureRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : sampleRate
        guard let captureFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: captureRate,
            channels: 1,
            interleaved: true
        ) else {
            AudioQueueDispose(queue, true)
            throw AudioRecorderError.setupFailed("Mic format failed")
        }
        let writeFormat = try Self.int16MonoFormat(sampleRate: captureRate)
        let target: ChunkWriteTarget
        if abs(provisionalTarget.sampleRate - writeFormat.sampleRate) < 1 {
            target = provisionalTarget
        } else {
            target = try ChunkWriteTarget(format: writeFormat)
        }
        let converter = AVAudioConverter(from: captureFormat, to: writeFormat)
        context.target = target
        context.writeGain = writeGain
        context.captureFormat = captureFormat
        context.writeFormat = writeFormat
        context.converter = converter

        let bufferBytes: UInt32 = max(2048, UInt32(asbd.mBytesPerFrame) * 1024)
        var kept: [AudioQueueBufferRef] = []
        for _ in 0..<3 {
            var buf: AudioQueueBufferRef?
            guard AudioQueueAllocateBuffer(queue, bufferBytes, &buf) == noErr, let buf else {
                AudioQueueDispose(queue, true)
                throw AudioRecorderError.setupFailed("Mic buffer alloc failed")
            }
            AudioQueueEnqueueBuffer(queue, buf, 0, nil)
            kept.append(buf)
        }

        let startStatus = AudioQueueStart(queue, nil)
        guard startStatus == noErr else {
            AudioQueueDispose(queue, true)
            throw AudioRecorderError.setupFailed("Mic queue start failed")
        }

        objc_setAssociatedObject(self, &AssociatedKeys.queueContext, context, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        self.audioQueue = queue
        self.queueBuffers = kept
        self.writeTarget = target
        self.usingAudioQueue = true
        NSLog(
            "Vocalis: AudioQueue recording on \(activeDeviceName) @ \(Int(captureRate)) Hz (Bluetooth, default route)"
        )
    }

    // MARK: - Shared

    private func tearDownCaptureKeepingWriter() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
        }
        engine = nil

        if let audioQueue {
            AudioQueueStop(audioQueue, true)
            AudioQueueDispose(audioQueue, true)
        }
        audioQueue = nil
        queueBuffers = []
        objc_setAssociatedObject(self, &AssociatedKeys.queueContext, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        usingAudioQueue = false
    }

    private func tearDownCapture(deleteFile: Bool) {
        tearDownCaptureKeepingWriter()

        if deleteFile, let url = writeTarget?.finish() {
            try? FileManager.default.removeItem(at: url)
        }
        writeTarget = nil
        setBufferCount(0)
        setLevel(0)
    }

    private func finishBluetoothRoute() {
        if isBluetoothSession {
            MicDevices.restoreDefaultOutput(uid: previousOutputUID)
            previousOutputUID = nil
            isBluetoothSession = false
        }
    }

    private func bindInputDevice(_ deviceID: AudioDeviceID, on input: AVAudioInputNode) throws {
        guard let audioUnit = input.audioUnit else {
            throw AudioRecorderError.setupFailed("No audio unit")
        }
        var id = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            size
        )
        if status != noErr {
            NSLog("Vocalis: bind input device failed (\(status)); using default route")
        }
    }

    private static func int16MonoFormat(sampleRate: Double) throws -> AVAudioFormat {
        let rate = sampleRate > 0 ? sampleRate : 24_000
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: rate,
            channels: 1,
            interleaved: true
        ) else {
            throw AudioRecorderError.setupFailed("Mic format failed")
        }
        return format
    }

    nonisolated private func handleEngineBuffer(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter?,
        target: ChunkWriteTarget,
        fileFormat: AVAudioFormat,
        writeGain: Float
    ) {
        guard let converter else { return }
        let capacity = AVAudioFrameCount(buffer.frameLength) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: capacity) else { return }

        // Apply gain in the float domain before converting to int16.
        if writeGain != 1, let floats = buffer.floatChannelData {
            let frames = Int(buffer.frameLength)
            for ch in 0..<Int(buffer.format.channelCount) {
                for i in 0..<frames {
                    floats[ch][i] = max(-1, min(1, floats[ch][i] * writeGain))
                }
            }
        }

        var consumed = false
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        converter.convert(to: out, error: &error, withInputFrom: inputBlock)
        guard error == nil, out.frameLength > 0 else {
            // Still publish pre-convert level so a converter glitch does not freeze the meter at 0.
            publishLevel(Self.displayLevel(from: buffer, gain: writeGain))
            return
        }
        // Meter what we actually write (post-gain int16) — matches audible capture.
        publishLevel(Self.displayLevel(from: out, gain: 1))
        target.write(out)
    }

    fileprivate nonisolated func handleQueueBuffer(
        _ audioData: UnsafeMutableRawPointer,
        byteSize: UInt32,
        target: ChunkWriteTarget,
        writeGain: Float,
        captureFormat: AVAudioFormat,
        writeFormat: AVAudioFormat,
        converter: AVAudioConverter?
    ) {
        let frames = Int(byteSize) / MemoryLayout<Float>.size
        guard frames > 0 else { return }
        let samples = audioData.bindMemory(to: Float.self, capacity: frames)

        guard let floatBuf = AVAudioPCMBuffer(
            pcmFormat: captureFormat,
            frameCapacity: AVAudioFrameCount(frames)
        ) else { return }
        floatBuf.frameLength = AVAudioFrameCount(frames)
        if let dst = floatBuf.floatChannelData?[0] {
            for i in 0..<frames {
                dst[i] = max(-1, min(1, samples[i] * writeGain))
            }
        }

        // Post-gain meter so AirPods HFP (quiet raw, gain ~6) still lights the bubble.
        publishLevel(Self.displayLevel(from: floatBuf, gain: 1))

        guard let converter,
              let out = AVAudioPCMBuffer(
                pcmFormat: writeFormat,
                frameCapacity: AVAudioFrameCount(frames) + 32
              ) else {
            return
        }
        var consumed = false
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return floatBuf
        }
        converter.convert(to: out, error: &error, withInputFrom: inputBlock)
        guard error == nil, out.frameLength > 0 else { return }
        target.write(out)
    }

    /// Map PCM to 0…1 for the bubble. Handles float and int16; max across channels.
    nonisolated private static func displayLevel(from buffer: AVAudioPCMBuffer, gain: Float) -> Float {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return 0 }

        var sum: Float = 0
        var peak: Float = 0
        var counted = 0

        if let floats = buffer.floatChannelData {
            for ch in 0..<channels {
                let samples = UnsafeBufferPointer(start: floats[ch], count: frames)
                for s in samples {
                    let v = s * gain
                    sum += v * v
                    peak = max(peak, abs(v))
                    counted += 1
                }
            }
        } else if let ints = buffer.int16ChannelData {
            let scale = gain / 32768.0
            for ch in 0..<channels {
                let samples = UnsafeBufferPointer(start: ints[ch], count: frames)
                for s in samples {
                    let v = Float(s) * scale
                    sum += v * v
                    peak = max(peak, abs(v))
                    counted += 1
                }
            }
        } else {
            return 0
        }

        guard counted > 0 else { return 0 }
        let rms = sqrt(sum / Float(counted))
        // Sensitive enough for soft speech / HFP; peak-hold in publishLevel smooths dips.
        return min(1, max(rms * 28, peak * 16))
    }
}

// MARK: - AudioQueue callback context

private enum AssociatedKeys {
    static var queueContext: UInt8 = 0
}

private final class QueueContext: @unchecked Sendable {
    weak var owner: AudioRecorder?
    var target: ChunkWriteTarget
    var writeGain: Float
    var captureFormat: AVAudioFormat
    var writeFormat: AVAudioFormat
    var converter: AVAudioConverter?

    init(
        owner: AudioRecorder,
        target: ChunkWriteTarget,
        writeGain: Float,
        captureFormat: AVAudioFormat,
        writeFormat: AVAudioFormat,
        converter: AVAudioConverter?
    ) {
        self.owner = owner
        self.target = target
        self.writeGain = writeGain
        self.captureFormat = captureFormat
        self.writeFormat = writeFormat
        self.converter = converter
    }

    func handle(buffer: AudioQueueBufferRef, queue: AudioQueueRef) {
        let byteSize = buffer.pointee.mAudioDataByteSize
        if byteSize > 0 {
            owner?.handleQueueBuffer(
                buffer.pointee.mAudioData,
                byteSize: byteSize,
                target: target,
                writeGain: writeGain,
                captureFormat: captureFormat,
                writeFormat: writeFormat,
                converter: converter
            )
        }
        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }
}
