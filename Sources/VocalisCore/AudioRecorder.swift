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
    private var latestLevel: Float = 0
    private var isBluetoothSession = false
    private var usingAudioQueue = false
    private var bufferCount: Int = 0
    private var writeGain: Float = 1
    /// Keep AirPods HFP warm across dictations so the next hold starts instantly.
    private var keepBluetoothWarm = true
    private var chunkTask: Task<Void, Never>?

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
        bufferCount = 0

        // Only wait when we actually flipped the route into HFP; warm path starts now.
        if isBluetoothSession, activation.routeChanged, !alreadyWarm {
            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        if isBluetoothSession {
            try startAudioQueue(device: device)
        } else {
            try startEngine(device: device)
        }
        startChunkTimerIfNeeded()
    }

    public func stop() throws -> URL {
        guard writeTarget != nil else { throw AudioRecorderError.notRecording }
        stopChunkTimer()
        let url = writeTarget?.finish()
        tearDownCapture(deleteFile: false)
        latestLevel = 0
        guard let url else { throw AudioRecorderError.notRecording }
        NSLog("Vocalis: stopped after \(bufferCount) buffers")
        return url
    }

    public func cancel() {
        stopChunkTimer()
        tearDownCapture(deleteFile: true)
        latestLevel = 0
        if !keepBluetoothWarm {
            finishBluetoothRoute()
        }
    }

    /// Restore previous output (call on app quit).
    public func releaseHardware() {
        keepBluetoothWarm = false
        stopChunkTimer()
        tearDownCapture(deleteFile: true)
        latestLevel = 0
        finishBluetoothRoute()
    }

    public func currentLevel() -> Float { latestLevel }

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

        let writeFormat = try monoWriteFormat(from: hwFormat)
        let target = try ChunkWriteTarget(format: writeFormat)

        let needsDownmix = writeFormat.channelCount != hwFormat.channelCount
            || writeFormat.commonFormat != hwFormat.commonFormat
        let converter = needsDownmix ? AVAudioConverter(from: hwFormat, to: writeFormat) : nil
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
        let rate = MicDevices.nominalSampleRate(uid: preferredDeviceUID)
        let sampleRate = rate > 0 ? rate : 24_000

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        guard let writeFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw AudioRecorderError.setupFailed("Mic format failed")
        }
        let target = try ChunkWriteTarget(format: writeFormat)

        let context = QueueContext(owner: self, target: target, writeGain: writeGain)
        var queue: AudioQueueRef?
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

        let uid = device?.uid
            ?? MicDevices.defaultInput()?.uid
            ?? ""
        if !uid.isEmpty {
            var cfUID = uid as CFString
            let sz = UInt32(MemoryLayout<CFString>.size)
            let setStatus = withUnsafePointer(to: &cfUID) { ptr in
                AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice, ptr, sz)
            }
            if setStatus != noErr {
                NSLog("Vocalis: AudioQueue set device failed (\(setStatus)); using default")
            }
        }

        let bufferBytes: UInt32 = 4096
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
            "Vocalis: AudioQueue recording on \(activeDeviceName) @ \(Int(sampleRate)) Hz (Bluetooth)"
        )
    }

    // MARK: - Shared

    private func tearDownCapture(deleteFile: Bool) {
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

        if deleteFile, let url = writeTarget?.finish() {
            try? FileManager.default.removeItem(at: url)
        }
        writeTarget = nil
        usingAudioQueue = false
        bufferCount = 0
        latestLevel = 0
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

    private func monoWriteFormat(from hwFormat: AVAudioFormat) throws -> AVAudioFormat {
        if hwFormat.channelCount == 1 { return hwFormat }
        if let mono = AVAudioFormat(
            commonFormat: hwFormat.commonFormat,
            sampleRate: hwFormat.sampleRate,
            channels: 1,
            interleaved: hwFormat.isInterleaved
        ) {
            return mono
        }
        throw AudioRecorderError.setupFailed("Mic format failed")
    }

    nonisolated private func handleEngineBuffer(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter?,
        target: ChunkWriteTarget,
        fileFormat: AVAudioFormat,
        writeGain: Float
    ) {
        let level = Self.displayLevel(fromFloatBuffer: buffer)
        Task { @MainActor in
            self.latestLevel = level
            self.bufferCount += 1
        }

        let toWrite: AVAudioPCMBuffer
        if let converter {
            let capacity = AVAudioFrameCount(buffer.frameLength) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: capacity) else { return }
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
            guard error == nil, out.frameLength > 0 else { return }
            toWrite = out
        } else {
            toWrite = buffer
        }

        if writeGain != 1, let gained = Self.gainedCopy(toWrite, gain: writeGain) {
            target.write(gained)
        } else {
            target.write(toWrite)
        }
    }

    fileprivate nonisolated func handleQueueBuffer(
        _ audioData: UnsafeMutableRawPointer,
        byteSize: UInt32,
        target: ChunkWriteTarget,
        writeGain: Float
    ) {
        let frames = Int(byteSize) / MemoryLayout<Float>.size
        guard frames > 0 else { return }
        let samples = audioData.bindMemory(to: Float.self, capacity: frames)

        var sum: Float = 0
        var peak: Float = 0
        for i in 0..<frames {
            let s = samples[i]
            sum += s * s
            peak = max(peak, abs(s))
        }
        let rms = sqrt(sum / Float(frames))
        let level = min(1, max(rms * 18, peak * 12))

        Task { @MainActor in
            self.latestLevel = level
            self.bufferCount += 1
        }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: target.sampleRate,
            channels: 1,
            interleaved: true
        ), let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            return
        }
        buf.frameLength = AVAudioFrameCount(frames)
        if let dst = buf.floatChannelData?[0] {
            for i in 0..<frames {
                dst[i] = max(-1, min(1, samples[i] * writeGain))
            }
        }
        target.write(buf)
    }

    nonisolated private static func displayLevel(fromFloatBuffer buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        if let channels = buffer.floatChannelData {
            let samples = UnsafeBufferPointer(start: channels[0], count: frames)
            var sum: Float = 0
            var peak: Float = 0
            for s in samples {
                sum += s * s
                peak = max(peak, abs(s))
            }
            let rms = sqrt(sum / Float(frames))
            return min(1, max(rms * 18, peak * 12))
        }
        return 0
    }

    nonisolated private static func gainedCopy(_ buffer: AVAudioPCMBuffer, gain: Float) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        out.frameLength = buffer.frameLength
        let frames = Int(buffer.frameLength)
        if let src = buffer.floatChannelData, let dst = out.floatChannelData {
            for ch in 0..<Int(buffer.format.channelCount) {
                for i in 0..<frames {
                    dst[ch][i] = max(-1, min(1, src[ch][i] * gain))
                }
            }
            return out
        }
        return nil
    }
}

// MARK: - AudioQueue callback context

private enum AssociatedKeys {
    static var queueContext: UInt8 = 0
}

private final class QueueContext: @unchecked Sendable {
    weak var owner: AudioRecorder?
    let target: ChunkWriteTarget
    let writeGain: Float

    init(owner: AudioRecorder, target: ChunkWriteTarget, writeGain: Float) {
        self.owner = owner
        self.target = target
        self.writeGain = writeGain
    }

    func handle(buffer: AudioQueueBufferRef, queue: AudioQueueRef) {
        let byteSize = buffer.pointee.mAudioDataByteSize
        if byteSize > 0 {
            owner?.handleQueueBuffer(
                buffer.pointee.mAudioData,
                byteSize: byteSize,
                target: target,
                writeGain: writeGain
            )
        }
        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }
}
