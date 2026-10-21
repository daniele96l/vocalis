import AVFoundation
import Foundation

/// Thread-safe WAV writer that can rotate mid-recording for live/parallel STT.
final class ChunkWriteTarget: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile
    private var url: URL
    private let format: AVAudioFormat
    private let makeURL: () -> URL
    private var framesWritten: AVAudioFramePosition = 0

    var sampleRate: Double { format.sampleRate }

    init(format: AVAudioFormat, makeURL: @escaping () -> URL = {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocalis-\(UUID().uuidString).wav")
    }) throws {
        self.format = format
        self.makeURL = makeURL
        let url = makeURL()
        self.url = url
        self.file = try AVAudioFile(forWriting: url, settings: format.settings)
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        do {
            try file.write(from: buffer)
            framesWritten += AVAudioFramePosition(buffer.frameLength)
        } catch {
            // Drop buffer rather than crash the audio thread.
        }
    }

    /// Seconds currently in the open chunk (approximate).
    func currentDurationSeconds() -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard format.sampleRate > 0 else { return 0 }
        return Double(framesWritten) / format.sampleRate
    }

    /// Close the current file and open a fresh one. Returns the sealed chunk URL.
    func rotate() throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        let sealed = url
        let sealedFrames = framesWritten
        let newURL = makeURL()
        let newFile = try AVAudioFile(forWriting: newURL, settings: format.settings)
        // Release old file (flush/close) by replacing references.
        file = newFile
        url = newURL
        framesWritten = 0
        // Reject empty seals at call site via sealedFrames / file size.
        _ = sealedFrames
        return sealed
    }

    func finish() -> URL {
        lock.lock()
        defer { lock.unlock() }
        return url
    }
}
