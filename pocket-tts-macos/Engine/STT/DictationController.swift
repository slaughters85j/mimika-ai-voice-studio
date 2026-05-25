//
//  DictationController.swift
//  pocket-tts-macos
//
//  Drives the Chat composer's mic-button dictation via SFSpeechRecognizer
//  + AVAudioEngine.
//
//  History (in this same file's prior commits): an attempt to migrate to
//  macOS 26's SpeechTranscriber / SpeechAnalyzer crashed at runtime even
//  after the obvious entitlement was added. The sandbox-vs-daemon dance
//  for the new framework needs more investigation than this session can
//  do without being able to interactively debug on the target machine.
//  Until that's resolved with verifiable tests, we ship the older
//  SFSpeechRecognizer path — it's slightly worse UX (Apple's system prompt
//  includes "Speech data from this app will be sent to Apple…") but it
//  doesn't crash. The Apple prompt boilerplate can't be suppressed; the
//  system controls it.

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
        case unavailable(String)
    }

    enum DictationError: Error, CustomStringConvertible {
        case notAuthorized
        case noMicrophone
        case audioEngineFailed(Error)
        case recognizerUnavailable
        case recognitionFailed(Error)

        var description: String {
            switch self {
            case .notAuthorized:        return "Speech recognition not authorized"
            case .noMicrophone:         return "No microphone input available"
            case .audioEngineFailed(let e): return "Audio engine failed: \(e)"
            case .recognizerUnavailable: return "Speech recognizer unavailable for this locale"
            case .recognitionFailed(let e):  return "Recognition failed: \(e)"
            }
        }
    }

    private(set) var authState: AuthState = .notDetermined

    var onTranscript: ((String) -> Void)?
    var onError: ((DictationError) -> Void)?

    /// Audio engine recreated per start() so inputNode is freshly initialized
    /// after permission state changes. Reusing across permission flips can
    /// leave inputFormat reporting zero rate/channels, tripping a CoreAudio
    /// precondition (EXC_BREAKPOINT on the audio thread) inside installTap.
    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer: SFSpeechRecognizer?

    init(locale: Locale = .init(identifier: "en-US")) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
    }

    // MARK: - Authorization

    func requestAuthorization() async {
        if recognizer == nil {
            authState = .unavailable("Speech recognizer not available for this locale")
            return
        }

        // Speech recognition permission.
        //
        // The callback is delivered on a background queue (TCC reply, then
        // dispatch root.default-qos), NOT the main actor. Because this class
        // is `@MainActor`, Swift 6 infers `@MainActor` isolation on any
        // closure literal we write inline here, and the runtime then trips
        // `_dispatch_assert_queue_fail` / `_swift_task_checkIsolatedSwift`
        // when the system calls it on the wrong queue.
        //
        // Routing through a `nonisolated static` helper detaches the inner
        // closure from MainActor inference so it can run wherever the
        // framework wants. The async result is awaited back on MainActor.
        let speechStatus = await Self.requestSpeechRecognitionAuthorization()
        switch speechStatus {
        case .notDetermined: authState = .notDetermined; return
        case .denied:        authState = .denied; return
        case .restricted:    authState = .restricted; return
        case .authorized:    break
        @unknown default:    authState = .unavailable("unknown speech auth state"); return
        }

        // Microphone permission.
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

    /// Detached wrapper around SFSpeechRecognizer's callback-based auth API.
    /// MUST stay `nonisolated` (and ideally `static`) so the inner closure
    /// doesn't inherit MainActor isolation from the enclosing class — see
    /// the long comment in `requestAuthorization()`.
    private nonisolated static func requestSpeechRecognitionAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
    }

    // MARK: - Start / stop

    func start() throws {
        guard case .authorized = authState else { throw DictationError.notAuthorized }
        guard let recognizer, recognizer.isAvailable else {
            throw DictationError.recognizerUnavailable
        }

        teardown()

        // Build @Sendable callbacks here (on MainActor) so the nonisolated
        // helper doesn't need a reference to `self`. Weak-self + @MainActor
        // Task hop keeps the access safe.
        let onResult: @Sendable (String) -> Void = { [weak self] text in
            Task { @MainActor in self?.onTranscript?(text) }
        }
        let onErr: @Sendable (Error) -> Void = { [weak self] error in
            Task { @MainActor in self?.onError?(.recognitionFailed(error)) }
        }

        // The entire audio pipeline setup runs through a nonisolated static
        // helper so that the installTap closure and recognitionTask handler
        // do NOT inherit @MainActor isolation. Swift 6 infers @MainActor on
        // closures declared inside a @MainActor method, and the runtime
        // traps when the system calls them on a background queue.
        let pipeline = try Self.setupAudioPipeline(
            recognizer: recognizer,
            onResult: onResult,
            onError: onErr
        )
        self.audioEngine = pipeline.engine
        self.request = pipeline.request
        self.task = pipeline.task
    }

    /// Builds the AVAudioEngine → SFSpeechRecognizer pipeline in a
    /// nonisolated context so that all closures (audio tap, recognition
    /// result handler) are free of @MainActor isolation inference.
    private nonisolated static func setupAudioPipeline(
        recognizer: SFSpeechRecognizer,
        onResult: @Sendable @escaping (String) -> Void,
        onError: @Sendable @escaping (Error) -> Void
    ) throws -> (engine: AVAudioEngine, request: SFSpeechAudioBufferRecognitionRequest, task: SFSpeechRecognitionTask) {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Use `outputFormat` not `inputFormat` — see Apple's SpokenWord
        // sample. `outputFormat` is what the node emits to the tap;
        // `inputFormat` is the raw hardware side. Mismatch triggers a
        // CoreAudio precondition.
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw DictationError.noMicrophone
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            req.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw DictationError.audioEngineFailed(error)
        }

        let task = recognizer.recognitionTask(with: req) { result, error in
            if let result {
                onResult(result.bestTranscription.formattedString)
            }
            if let error {
                let nsErr = error as NSError
                // Code 203 is the normal "stop() was called" signal, not a real error.
                if !(nsErr.code == 203 && nsErr.domain == "kAFAssistantErrorDomain") {
                    onError(error)
                }
            }
        }

        return (engine, req, task)
    }

    func stop() {
        if let engine = audioEngine, engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        request = nil
    }

    func cancel() {
        teardown()
    }

    // MARK: - Private

    private func teardown() {
        task?.cancel()
        task = nil
        request = nil
        if let engine = audioEngine {
            if engine.isRunning {
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
            }
        }
        audioEngine = nil
    }
}
