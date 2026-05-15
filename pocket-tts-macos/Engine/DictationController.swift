//
//  DictationController.swift
//  pocket-tts-macos
//
//  Wraps Apple's Speech framework (SFSpeechRecognizer) + AVAudioEngine
//  microphone capture to power the Chat composer's mic-button dictation.
//
//  Lifecycle (driven by ChatViewModel):
//    1. requestAuthorization() — async; succeeds, denied, or restricted.
//    2. start() — opens an audio input tap and a recognition request.
//       Partial transcripts arrive via the `onTranscript` callback.
//    3. stop() — flushes the recognizer, tears down the audio tap. The most
//       recent transcript is the final one.
//
//  Strict-on-device when supported (privacy + offline). Falls back to
//  server-side automatically if on-device isn't available for the locale.

import AVFoundation
import Foundation
import Speech

@MainActor
final class DictationController {

    enum AuthState: Equatable {
        case notDetermined
        case authorized
        case denied
        case restricted
        case unavailable(String)   // device / framework error
    }

    enum DictationError: Error, CustomStringConvertible {
        case notAuthorized
        case audioSessionFailed(Error)
        case recognizerUnavailable
        case recognitionFailed(Error)

        var description: String {
            switch self {
            case .notAuthorized:        return "Speech recognition not authorized"
            case .audioSessionFailed(let e): return "Audio engine failed: \(e)"
            case .recognizerUnavailable: return "Speech recognizer unavailable for this locale"
            case .recognitionFailed(let e):  return "Recognition failed: \(e)"
            }
        }
    }

    // MARK: - State
    private(set) var authState: AuthState = .notDetermined

    /// Callback fired on each partial recognition result. Always invoked on
    /// the main actor.
    var onTranscript: ((String) -> Void)?

    /// Callback fired if recognition fails partway through.
    var onError: ((DictationError) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer: SFSpeechRecognizer?

    init(locale: Locale = .init(identifier: "en-US")) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
    }

    // MARK: - Authorization

    /// Request mic + speech-recognition authorization. Two prompts the first
    /// time (one per permission); cached thereafter.
    func requestAuthorization() async {
        if recognizer == nil {
            authState = .unavailable("Speech recognizer not available for this locale")
            return
        }

        // Speech recognition permission.
        let speechStatus: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status) }
        }
        switch speechStatus {
        case .notDetermined: authState = .notDetermined; return
        case .denied:        authState = .denied; return
        case .restricted:    authState = .restricted; return
        case .authorized:    break
        @unknown default:    authState = .unavailable("unknown speech auth state"); return
        }

        // Microphone permission. macOS uses AVCaptureDevice authorization.
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch micStatus {
        case .authorized:
            authState = .authorized
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            authState = granted ? .authorized : .denied
        case .denied:
            authState = .denied
        case .restricted:
            authState = .restricted
        @unknown default:
            authState = .unavailable("unknown mic auth state")
        }
    }

    // MARK: - Start / stop

    func start() throws {
        guard case .authorized = authState else { throw DictationError.notAuthorized }
        guard let recognizer, recognizer.isAvailable else {
            throw DictationError.recognizerUnavailable
        }

        // Tear down any previous run defensively.
        task?.cancel()
        task = nil
        request = nil
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)

        // Build a fresh request. Prefer on-device when supported.
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        self.request = req

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req] buffer, _ in
            req?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.request = nil
            throw DictationError.audioSessionFailed(error)
        }

        // Start the recognition task. The result callback runs on a
        // recognizer-internal queue; we hop back to MainActor before firing
        // user callbacks.
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                Task { @MainActor in self.onTranscript?(text) }
            }
            if let error {
                // `.cancelled` is what our stop() induces; not a real error.
                let nsErr = error as NSError
                if nsErr.code != 203 && nsErr.domain != "kAFAssistantErrorDomain" {
                    Task { @MainActor in self.onError?(.recognitionFailed(error)) }
                }
            }
        }
    }

    /// Stops listening but lets the recognizer flush its final transcript.
    func stop() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        // Don't cancel the task — endAudio lets the recognizer deliver one
        // final result, which our callback will surface.
        request = nil
    }

    /// Hard cancel — drops any in-flight result.
    func cancel() {
        task?.cancel()
        task = nil
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request = nil
    }
}
