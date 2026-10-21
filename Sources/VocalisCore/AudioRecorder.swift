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
@MainActor
public final class AudioRecorder: NSObject {
    /// UID from config; empty = system default.
    public var preferredDeviceUID: String = ""
    public private(set) var activeDeviceName: String = MicDevices.displayName(forUID: "")

    private var engine: AVAudioEngine?
    private var audioQueue: AudioQueueRef?
    private var queueBuffers: [AudioQueueBufferRef] = []
    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private var previousOutputUID: String?
    private var latestLevel: Float = 0
    private var isBluetoothSession = false
    private var usingAudioQueue = false
    private var bufferCount: Int = 0
    private var writeGain: Float = 1

    public var isRecording: Bool {
        if usingAudioQueue { return audioQueue != nil }
        return engine?.isRunning == true
    }

    public func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    public func start() async throws {
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            throw AudioRecorderError.permissionDenied
        }
        cancel()

        let device = MicDevices.device(uid: preferredDeviceUID)
        let activation = MicDevices.activateInput(uid: preferredDeviceUID)
        previousOutputUID = activation.previousOutputUID
        isBluetoothSession = device?.isBluetooth == true
        activeDeviceName = MicDevices.displayName(forUID: preferredDeviceUID)
        writeGain = isBluetoothSession ? 6.0 : 1.0
        bufferCount = 0
        latestLevel = 0

        if isBluetoothSession {
            try? await Task.sleep(nanoseconds: 600_000_000)
            try startAudioQueue(device: device)
        } else {
            try startEngine(device: device)
        }
    }

    public func stop() throws -> URL {
        guard let outputURL else { throw AudioRecorderError.notRecording }
        tearDownCapture(deleteFile: false)
        let url = outputURL
        self.outputURL = nil
        latestLevel = 0
        finishBluetoothRoute()
        NSLog("Vocalis: stopped after \(bufferCount) buffers")
        return url
    }

    public func cancel() {
        tearDownCapture(deleteFile: true)
        outputURL = nil
        latestLevel = 0
        finishBluetoothRoute()
    }

    public func currentLevel() -> Float { latestLevel }

    // MARK: - Engine (wired / built-in)

    private func startEngine(device: MicDevice?) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode

        // Do not bind CurrentDevice for Bluetooth (handled elsewhere). For explicit
        // non-default wired mics, bind only when needed.
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

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocalis-\(UUID().uuidString).wav")
        let writeFormat = try monoWriteFormat(from: hwFormat)
        let file = try AVAudioFile(forWriting: url, settings: writeFormat.settings)

        let needsDownmix = writeFormat.channelCount != hwFormat.channelCount
            || writeFormat.commonFormat != hwFormat.commonFormat
        let converter = needsDownmix ? AVAudioConverter(from: hwFormat, to: writeFormat) : nil

        let gain = writeGain
        input.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, _ in
            self?.handleEngineBuffer(
                buffer,
                converter: converter,
                file: file,
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
        self.audioFile = file
        self.outputURL = url
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

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocalis-\(UUID().uuidString).wav")
        guard let writeFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw AudioRecorderError.setupFailed("Mic format failed")
        }
        let file = try AVAudioFile(forWriting: url, settings: writeFormat.settings)

        let context = QueueContext(owner: self, file: file, writeGain: writeGain)
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

        // Prefer explicit AirPods input UID; else whatever is system default.
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

        // Keep context alive for the lifetime of the queue.
        objc_setAssociatedObject(self, &AssociatedKeys.queueContext, context, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        self.audioQueue = queue
        self.queueBuffers = kept
        self.audioFile = file
        self.outputURL = url
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

        audioFile = nil
        if deleteFile, let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        usingAudioQueue = false
        bufferCount = 0
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
        file: AVAudioFile,
        fileFormat: AVAudioFormat,
        writeGain: Float
    ) {
        let level = Self.displayLevel(fromFloatBuffer: buffer)
        let gain = writeGain
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

        if gain != 1, let gained = Self.gainedCopy(toWrite, gain: gain) {
            try? file.write(from: gained)
        } else {
            try? file.write(from: toWrite)
        }
    }

    fileprivate nonisolated func handleQueueBuffer(
        _ audioData: UnsafeMutableRawPointer,
        byteSize: UInt32,
        file: AVAudioFile,
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
            sampleRate: file.fileFormat.sampleRate,
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
        try? file.write(from: buf)
    }

    /// AirPods HFP peaks are often tiny — scale so the meter moves.
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
    let file: AVAudioFile
    let writeGain: Float

    init(owner: AudioRecorder, file: AVAudioFile, writeGain: Float) {
        self.owner = owner
        self.file = file
        self.writeGain = writeGain
    }

    func handle(buffer: AudioQueueBufferRef, queue: AudioQueueRef) {
        let byteSize = buffer.pointee.mAudioDataByteSize
        if byteSize > 0 {
            owner?.handleQueueBuffer(
                buffer.pointee.mAudioData,
                byteSize: byteSize,
                file: file,
                writeGain: writeGain
            )
        }
        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }
}
