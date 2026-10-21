import AVFoundation
import Foundation

enum AudioFormatConversion {
    /// xAI Grok STT returns 400 "Audio contains no samples" for IEEE-float WAVs
    /// that Vocalis records. Convert to mono 16-bit PCM WAV before upload.
    static func grokCompatibleWAV(from sourceURL: URL) throws -> URL {
        let source = try AVAudioFile(forReading: sourceURL)
        let inFormat = source.processingFormat
        let totalFrames = AVAudioFrameCount(source.length)
        guard totalFrames > 0 else { throw OpenAIClientError.emptyAudio }

        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: totalFrames) else {
            throw OpenAIClientError.decode
        }
        try source.read(into: inBuffer, frameCount: totalFrames)

        let rate = inFormat.sampleRate > 0 ? inFormat.sampleRate : 24_000
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: rate,
            channels: 1,
            interleaved: true
        ) else {
            throw OpenAIClientError.decode
        }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocalis-grok-\(UUID().uuidString).wav")
        let outFile = try AVAudioFile(
            forWriting: outURL,
            settings: outFormat.settings,
            commonFormat: outFormat.commonFormat,
            interleaved: outFormat.isInterleaved
        )

        if inFormat.commonFormat == .pcmFormatInt16, inFormat.channelCount == 1 {
            try outFile.write(from: inBuffer)
        } else if let converter = AVAudioConverter(from: inFormat, to: outFormat) {
            let capacity = AVAudioFrameCount(Double(inBuffer.frameLength) + 32)
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
                throw OpenAIClientError.decode
            }
            var error: NSError?
            var consumed = false
            let inputBlock: AVAudioConverterInputBlock = { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return inBuffer
            }
            converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
            if let error { throw error }
            guard outBuffer.frameLength > 0 else { throw OpenAIClientError.emptyAudio }
            try outFile.write(from: outBuffer)
        } else {
            throw OpenAIClientError.decode
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: outURL.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        if size < 800 {
            try? FileManager.default.removeItem(at: outURL)
            throw OpenAIClientError.emptyAudio
        }
        return outURL
    }
}
