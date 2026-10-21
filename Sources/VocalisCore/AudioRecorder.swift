import AVFoundation
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

/// Records via AVAudioEngine at the hardware sample rate.
/// AVAudioRecorder forced to 16 kHz AAC often captures silence from AirPods.
@MainActor
public final class AudioRecorder: NSObject {
    /// UID from config; empty = system default.
    public var preferredDeviceUID: String = ""
    public private(set) var activeDeviceName: String = MicDevices.displayName(forUID: "")

    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private var previousOutputUID: String?
    private var latestLevel: Float = 0
    private var isBluetoothSession = false

    public var isRecording: Bool { engine?.isRunning == true }

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

        // AirPods need time to enter headset/HFP mode after the route change.
        if isBluetoothSession {
            try? await Task.sleep(nanoseconds: 800_000_000)
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode

        // Never bind Bluetooth via CurrentDevice — that yields a running engine with
        // zero input buffers on AirPods. Route via system default only (activateInput).
        // Only bind explicit non-BT picks (USB etc.) when not already the default.
        if let device, !device.isBluetooth, !preferredDeviceUID.isEmpty {
            let currentDefault = MicDevices.defaultInput()?.coreAudioID
            if currentDefault != device.coreAudioID {
                try bindInputDevice(device.coreAudioID, on: input)
            }
        }

        engine.prepare()

        // Re-query — Bluetooth format settles after default-route activation.
        var hwFormat = input.inputFormat(forBus: 0)
        if (hwFormat.sampleRate <= 0 || hwFormat.channelCount == 0), isBluetoothSession {
            for _ in 0..<6 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                hwFormat = input.inputFormat(forBus: 0)
                if hwFormat.sampleRate > 0, hwFormat.channelCount > 0 { break }
            }
        }
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw AudioRecorderError.setupFailed("Mic format unavailable — try Built-in mic")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocalis-\(UUID().uuidString).wav")

        let writeFormat: AVAudioFormat
        if hwFormat.channelCount == 1 {
            writeFormat = hwFormat
        } else if let mono = AVAudioFormat(
            commonFormat: hwFormat.commonFormat,
            sampleRate: hwFormat.sampleRate,
            channels: 1,
            interleaved: hwFormat.isInterleaved
        ) {
            writeFormat = mono
        } else {
            throw AudioRecorderError.setupFailed("Mic format failed")
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: writeFormat.settings)
        } catch {
            throw AudioRecorderError.setupFailed("Could not open capture file")
        }

        let needsDownmix = writeFormat.channelCount != hwFormat.channelCount
            || writeFormat.commonFormat != hwFormat.commonFormat
        let converter = needsDownmix ? AVAudioConverter(from: hwFormat, to: writeFormat) : nil

        let bluetoothGain: Float = isBluetoothSession ? 6.0 : 1.0

        input.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, _ in
            self?.handleBuffer(
                buffer,
                converter: converter,
                file: file,
                fileFormat: writeFormat,
                writeGain: bluetoothGain
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
        self.latestLevel = 0
        NSLog(
            "Vocalis: recording on \(activeDeviceName) @ \(Int(hwFormat.sampleRate)) Hz"
                + (isBluetoothSession ? " (Bluetooth)" : "")
        )
    }

    public func stop() throws -> URL {
        guard let engine, let outputURL else {
            throw AudioRecorderError.notRecording
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        self.audioFile = nil
        let url = outputURL
        self.outputURL = nil
        latestLevel = 0
        finishBluetoothRoute()
        return url
    }

    public func cancel() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
        }
        engine = nil
        audioFile = nil
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        outputURL = nil
        latestLevel = 0
        finishBluetoothRoute()
    }

    public func currentLevel() -> Float {
        latestLevel
    }

    // MARK: - Private

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

    nonisolated private func handleBuffer(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter?,
        file: AVAudioFile,
        fileFormat: AVAudioFormat,
        writeGain: Float
    ) {
        let level = Self.displayLevel(buffer)
        Task { @MainActor in
            self.latestLevel = level
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
            try? file.write(from: gained)
        } else {
            try? file.write(from: toWrite)
        }
    }

    /// AirPods HFP peaks ~0.02 — scale so the meter actually moves.
    nonisolated private static func displayLevel(_ buffer: AVAudioPCMBuffer) -> Float {
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
        if let channels = buffer.int16ChannelData {
            let samples = UnsafeBufferPointer(start: channels[0], count: frames)
            var sum: Float = 0
            var peak: Float = 0
            for s in samples {
                let f = Float(s) / Float(Int16.max)
                sum += f * f
                peak = max(peak, abs(f))
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
        if let src = buffer.int16ChannelData, let dst = out.int16ChannelData {
            for ch in 0..<Int(buffer.format.channelCount) {
                for i in 0..<frames {
                    let v = Int(Float(src[ch][i]) * gain)
                    dst[ch][i] = Int16(clamping: v)
                }
            }
            return out
        }
        return nil
    }
}
