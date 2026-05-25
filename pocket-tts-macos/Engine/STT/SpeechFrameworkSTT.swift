//
//  SpeechFrameworkSTT.swift
//  pocket-tts-macos
//
//  Reference / fallback STTProvider built on Apple's `Speech` framework
//  (`SFSpeechRecognizer`). The production Voice Changer path now uses
//  FluidAudio / Parakeet; this stays as the Apple Speech backend for
//  reference and possible fallback use.
//
//  Notes:
//    * `Speech` capability + `NSSpeechRecognitionUsageDescription` are
//      already in place for the live-mic DictationController flow;
//      file-based recognition reuses the same auth path.
//    * `requiresOnDeviceRecognition = true` keeps audio off Apple's
//      servers; requires the locale's offline model installed via
//      Settings → General → Language & Region. When unavailable,
//      `recognitionTask` errors with `.serverFallbackDisallowed` and
//      we surface that to the user.
//    * SFTranscriptionSegment is WORD-level. We coalesce consecutive
//      words whose inter-word gap is below `utteranceGapSec` into a
//      single TranscribedSegment, so the downstream `[Xs]` pause
//      markers land between natural utterances rather than between
//      every word.

@preconcurrency import Speech
import Foundation

actor SpeechFrameworkSTT: STTProvider {

    enum STTError: Error, CustomStringConvertible {
        case notAuthorized(SFSpeechRecognizerAuthorizationStatus)
        case recognizerUnavailable(Locale)
        case recognitionFailed(Error)

        var description: String {
            switch self {
            case .notAuthorized(let status):
                return "speech recognition not authorized (status raw=\(status.rawValue))"
            case .recognizerUnavailable(let locale):
                return "SFSpeechRecognizer unavailable for locale \(locale.identifier)"
            case .recognitionFailed(let err):
                return "speech recognition failed: \(err.localizedDescription)"
            }
        }
    }

    private let locale: Locale
    private let requiresOnDevice: Bool
    private let addsPunctuation: Bool
    private let utteranceGapSec: Double

    init(
        locale: Locale = Locale(identifier: "en-US"),
        requiresOnDevice: Bool = true,
        addsPunctuation: Bool = true,
        utteranceGapSec: Double = 0.3
    ) {
        self.locale = locale
        self.requiresOnDevice = requiresOnDevice
        self.addsPunctuation = addsPunctuation
        self.utteranceGapSec = utteranceGapSec
    }

    func transcribeSegments(_ audio: URL) async throws -> [TranscribedSegment] {
        try await Self.authorize()

        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw STTError.recognizerUnavailable(locale)
        }

        let request = SFSpeechURLRecognitionRequest(url: audio)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = requiresOnDevice
        if #available(macOS 13.0, iOS 16.0, *) {
            request.addsPunctuation = addsPunctuation
        }

        // shouldReportPartialResults=false → handler fires once with
        // isFinal=true. The OneShot guard protects against the
        // (undocumented but observed) case where an error also fires.
        let words: [WordSpan] = try await withCheckedThrowingContinuation { cont in
            let oneShot = OneShot()
            _ = recognizer.recognitionTask(with: request) { result, err in
                if let err {
                    if oneShot.fire() {
                        cont.resume(throwing: STTError.recognitionFailed(err))
                    }
                    return
                }
                guard let result, result.isFinal else { return }
                let extracted = result.bestTranscription.segments.map {
                    WordSpan(substring: $0.substring,
                             timestamp: $0.timestamp,
                             duration: $0.duration)
                }
                if oneShot.fire() {
                    cont.resume(returning: extracted)
                }
            }
        }

        return Self.coalesce(words, utteranceGapSec: utteranceGapSec)
    }

    // MARK: - Helpers

    nonisolated struct WordSpan: Sendable {
        let substring: String
        let timestamp: TimeInterval
        let duration: TimeInterval
    }

    /// `nonisolated static` so the callback-passing closure does NOT
    /// inherit actor isolation — the callback is delivered on a
    /// background queue (TCC reply → dispatch root.default-qos),
    /// and inheriting actor isolation would trip
    /// `_dispatch_assert_queue_fail` (same pattern documented at length
    /// in DictationController.swift's `requestAuthorization()`).
    private nonisolated static func authorize() async throws {
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard status == .authorized else {
            throw STTError.notAuthorized(status)
        }
    }

    /// Group per-word spans into utterance-level TranscribedSegments.
    /// Adjacent words whose gap < `utteranceGapSec` belong to the same
    /// utterance. Mirrors how humans naturally clause speech and keeps
    /// the downstream `[Xs]` markers from peppering every word
    /// boundary.
    ///
    /// - Parameter separator: how adjacent spans within the same
    ///   utterance get joined. Defaults to `" "` for the original
    ///   word-level callers (Apple Speech-style spans) whose spans
    ///   are bare words without embedded whitespace. Pass `""` for
    ///   SentencePiece-style sub-word token callers (FluidAudio /
    ///   Parakeet) whose spans already encode word boundaries via a
    ///   leading space on word-start tokens — adding another space
    ///   between them would double-space and turn "▁eat" + "ing"
    ///   into "eat ing" instead of "eating". The leading space on
    ///   the first word-start token surfaces as a single leading
    ///   space on the segment text, which we trim once at the
    ///   segment boundary below.
    nonisolated static func coalesce(
        _ words: [WordSpan],
        utteranceGapSec: Double,
        separator: String = " "
    ) -> [TranscribedSegment] {
        guard !words.isEmpty else { return [] }
        var out: [TranscribedSegment] = []
        var buffer: [String] = [words[0].substring]
        var startSec: Double = words[0].timestamp
        var endSec: Double = words[0].timestamp + words[0].duration

        for w in words.dropFirst() {
            let gap = w.timestamp - endSec
            if gap >= utteranceGapSec {
                out.append(TranscribedSegment(
                    text: buffer.joined(separator: separator)
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    startSec: startSec,
                    endSec: endSec
                ))
                buffer = [w.substring]
                startSec = w.timestamp
            } else {
                buffer.append(w.substring)
            }
            endSec = w.timestamp + w.duration
        }
        out.append(TranscribedSegment(
            text: buffer.joined(separator: separator)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            startSec: startSec,
            endSec: endSec
        ))
        return out
    }

    /// Single-shot guard for the recognition callback. SFSpeechRecognizer
    /// is documented to call the handler once at isFinal under
    /// `shouldReportPartialResults=false`, but defensive coding because
    /// `CheckedContinuation` traps on double-resume.
    private final class OneShot: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func fire() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if fired { return false }
            fired = true
            return true
        }
    }
}
