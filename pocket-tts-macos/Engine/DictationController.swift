//
//  DictationController.swift
//  pocket-tts-macos
//
//  Drives the Chat composer's mic-button dictation. Uses macOS 26's
//  SpeechTranscriber / SpeechAnalyzer (fully on-device — no SFSpeechRecognizer,
//  no "Speech data from this app will be sent to Apple…" boilerplate, and no
//  separate speech-recognition entitlement on top of mic access).
//
//  Lifecycle (driven by ChatViewModel):
//    1. requestAuthorization() — async; resolves to .authorized once mic
//       access is granted.
//    2. start() — sets up a fresh AVAudioEngine input tap, a SpeechAnalyzer
//       with a SpeechTranscriber module, and an AsyncStream<AnalyzerInput>
//       that feeds mic buffers into the analyzer. Partial transcripts arrive
//       via `onTranscript`.
//    3. stop() — closes the input stream, tears down the audio tap; the
//       analyzer flushes one last result before its task ends.

import AVFoundation
import Foundation
import Speech

@available(macOS 26.0, *)
@MainActor
final class DictationController {

    // MARK: - State

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
        case analyzerSetupFailed(Error)
        case localeUnsupported

        var description: String {
            switch self {
            case .notAuthorized:               return "Microphone not authorized"
            case .noMicrophone:                return "No microphone input available"
            case .audioEngineFailed(let e):    return "Audio engine failed: \(e)"
            case .analyzerSetupFailed(let e):  return "Speech analyzer failed: \(e)"
            case .localeUnsupported:           return "Speech transcription unsupported for this locale"
            }
        }
    }

    private(set) var authState: AuthState = .notDetermined

    /// Fired on each partial transcript update. Always invoked on the main actor.
    var onTranscript: ((String) -> Void)?
    /// Fired on irrecoverable errors.
    var onError: ((DictationError) -> Void)?

    // MARK: - Stored
    // Audio engine is recreated per start() so the inputNode is freshly
    // initialized after permission state changes. Reusing one engine across
    // permission flips can leave inputFormat reporting zero rate/channels,
    // tripping a precondition deep in CoreAudio on the audio thread.
    private let locale: Locale
    private var audioEngine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerTask: Task<Void, Never>?

    init(locale: Locale = .init(identifier: "en-US")) {
        self.locale = locale
    }

    // MARK: - Authorization

    func requestAuthorization() async {
        // SpeechTranscriber runs locally — only the microphone permission
        // matters. No separate speech-recognition prompt.
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
            authState = .unavailable("unknown mic authorization state")
        }
    }

    // MARK: - Start / stop

    func start() throws {
        guard case .authorized = authState else { throw DictationError.notAuthorized }

        // Reset any prior run.
        teardown()

        // Fresh engine each start — see note above.
        let engine = AVAudioEngine()
        self.audioEngine = engine

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            self.audioEngine = nil
            throw DictationError.noMicrophone
        }

        // Build the analyzer + transcriber pair.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.transcriber = transcriber
        self.analyzer = analyzer

        // Input plumbing: audio tap → AsyncStream<AnalyzerInput> → analyzer.
        let (inputSeq, inputCont) = AsyncStream<AnalyzerInput>.makeStream(of: AnalyzerInput.self)
        self.inputContinuation = inputCont

        analyzerTask = Task { [weak self] in
            do {
                try await analyzer.start(inputSequence: inputSeq)
            } catch {
                Task { @MainActor in self?.onError?(.analyzerSetupFailed(error)) }
            }
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            inputCont.yield(AnalyzerInput(buffer: buffer))
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            inputCont.finish()
            self.audioEngine = nil
            throw DictationError.audioEngineFailed(error)
        }

        // Stream results back to the caller.
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    await MainActor.run { self?.onTranscript?(text) }
                }
            } catch {
                await MainActor.run { self?.onError?(.analyzerSetupFailed(error)) }
            }
        }
    }

    /// Stop listening; allow the analyzer to flush one final result.
    func stop() {
        inputContinuation?.finish()
        inputContinuation = nil
        if let engine = audioEngine, engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        // Let the results task drain naturally as the analyzer winds down.
    }

    /// Hard cancel — discards any in-flight result.
    func cancel() {
        teardown()
    }

    // MARK: - Private

    private func teardown() {
        inputContinuation?.finish()
        inputContinuation = nil

        if let engine = audioEngine, engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil

        resultsTask?.cancel()
        resultsTask = nil
        analyzerTask?.cancel()
        analyzerTask = nil
        analyzer = nil
        transcriber = nil
    }
}
