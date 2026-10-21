import AVFoundation
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

@MainActor
public final class AudioRecorder: NSObject {
    private var recorder: AVAudioRecorder?
    private var outputURL: URL?
    /// UID from config; empty = system default.
    public var preferredDeviceUID: String = ""
    public private(set) var activeDeviceName: String = MicDevices.displayName(forUID: "")

    public var isRecording: Bool { recorder?.isRecording == true }

    public func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    public func start() throws {
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            throw AudioRecorderError.permissionDenied
        }

        _ = MicDevices.setDefaultInput(uid: preferredDeviceUID)
        activeDeviceName = MicDevices.displayName(forUID: preferredDeviceUID)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocalis-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord(), recorder.record() else {
                throw AudioRecorderError.setupFailed("Mic start failed")
            }
            self.recorder = recorder
            self.outputURL = url
        } catch let error as AudioRecorderError {
            throw error
        } catch {
            throw AudioRecorderError.setupFailed("Mic start failed")
        }
    }

    public func stop() throws -> URL {
        guard let recorder, let outputURL else {
            throw AudioRecorderError.notRecording
        }
        recorder.stop()
        self.recorder = nil
        self.outputURL = nil
        return outputURL
    }

    public func cancel() {
        recorder?.stop()
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        recorder = nil
        self.outputURL = nil
    }

    public func currentLevel() -> Float {
        guard let recorder, recorder.isRecording else { return 0 }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        // Map dB (-55...0) to 0...1 — leave headroom so quiet rooms aren't flat zero.
        return max(0, min(1, (power + 55) / 55))
    }
}
