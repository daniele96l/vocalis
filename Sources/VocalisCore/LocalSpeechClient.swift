import AVFoundation
import CoreMedia
import Foundation
import Speech

public enum LocalSpeechError: LocalizedError {
    case notAuthorized
    case unavailable
    case onDeviceUnsupported
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Allow Speech Recognition"
        case .unavailable: return "Local speech unavailable"
        case .onDeviceUnsupported: return "On-device speech unsupported"
        case .failed(let msg): return msg
        }
    }
}

/// Apple Speech framework — on-device when possible (no cloud STT cost).
public enum LocalSpeechClient {
    public static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    public static func transcribe(audioURL: URL, languages: [String]) async throws -> TranscriptionResult {
        let status = SFSpeechRecognizer.authorizationStatus()
        let authorized: Bool
        if status == .authorized {
            authorized = true
        } else if status == .notDetermined {
            authorized = await requestAuthorization() == .authorized
        } else {
            authorized = false
        }
        guard authorized else { throw LocalSpeechError.notAuthorized }

        let locale = preferredLocale(languages: languages)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw LocalSpeechError.unavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let text: String = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            var settled = false
            let recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                if settled { return }
                if let error {
                    settled = true
                    continuation.resume(throwing: LocalSpeechError.failed(error.localizedDescription))
                    return
                }
                guard let result, result.isFinal else { return }
                settled = true
                continuation.resume(returning: result.bestTranscription.formattedString)
            }
            // Retain until finished; cancel if we somehow lose the callback.
            _ = recognitionTask
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw OpenAIClientError.emptyTranscript }

        let duration = audioDurationSeconds(url: audioURL)
        let result = TranscriptionResult(
            text: trimmed,
            model: ModelCatalog.localAppleSpeech,
            durationSeconds: duration
        )
        UsageLedger.recordSTT(model: result.model, audioSeconds: result.durationSeconds)
        return result
    }

    private static func preferredLocale(languages: [String]) -> Locale {
        let codes = LanguageCatalog.normalize(languages)
        for code in codes {
            let locale = Locale(identifier: code)
            if SFSpeechRecognizer(locale: locale)?.isAvailable == true {
                return locale
            }
        }
        return Locale.current
    }

    private static func audioDurationSeconds(url: URL) -> Double {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        if seconds.isFinite, seconds > 0 { return seconds }
        return 1
    }
}
