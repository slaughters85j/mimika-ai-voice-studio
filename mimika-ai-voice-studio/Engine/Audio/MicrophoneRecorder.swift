//
//  MicrophoneRecorder.swift
//  mimika-ai-voice-studio
//
//  Captures mono reference audio from the system microphone for the Voice
//  Manager's "Record Voice" flow. Reuses the same AVAudioEngine input-tap
//  approach as the dictation pipeline (Engine/STT/DictationController) and the
//  already-granted `com.apple.security.device.audio-input` entitlement +
//  NSMicrophoneUsageDescription.
//
//  The audio render thread writes mono samples into a lock-guarded
//  `RecordingSampleSink`; the view model polls it on the main actor for the
//  live level + elapsed time and drains it when recording stops. Capture is
//  capped (default 30 s) so a forgotten recording can't grow unbounded.
//

import AVFoundation

// MARK: - RecordingSampleSink
// Thread-safe bridge between the realtime audio tap (writer) and the main-actor
// view model (reader). `@unchecked Sendable` because all access is serialized
// by `lock`.

// `nonisolated` opts the sink out of this module's default-MainActor isolation
// so the realtime audio tap can call `append` directly; thread-safety is
// provided by `lock`, hence `@unchecked Sendable`.
nonisolated final class RecordingSampleSink: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [Float] = []
    private var capped = false
    private var lastLevel: Float = 0

    func reset(capacity: Int) {
        lock.lock(); defer { lock.unlock() }
        buffer.removeAll(keepingCapacity: false)
        buffer.reserveCapacity(capacity)
        capped = false
        lastLevel = 0
    }

    /// Down-mix `pcm` to mono, apply capture `gain`, and append, stopping at
    /// `cap` frames. Runs on the realtime audio thread — keep it
    /// allocation-light and lock-brief. `tanh` makes the boost near-linear for
    /// quiet input (the common case) while smoothly saturating transients
    /// rather than hard-clipping.
    func append(_ pcm: AVAudioPCMBuffer, cap: Int, gain: Float) {
        guard let channels = pcm.floatChannelData else { return }
        let frames = Int(pcm.frameLength)
        guard frames > 0 else { return }
        let channelCount = Int(pcm.format.channelCount)

        var mono = [Float](repeating: 0, count: frames)
        if channelCount <= 1 {
            let src = channels[0]
            for i in 0..<frames { mono[i] = tanh(src[i] * gain) }
        } else {
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channelCount { sum += channels[c][i] }
                mono[i] = tanh((sum / Float(channelCount)) * gain)
            }
        }

        var sumSq: Float = 0
        for v in mono { sumSq += v * v }
        let rms = (sumSq / Float(frames)).squareRoot()

        lock.lock(); defer { lock.unlock() }
        lastLevel = rms
        guard !capped else { return }
        let room = cap - buffer.count
        if room <= 0 { capped = true; return }
        if frames >= room {
            buffer.append(contentsOf: mono[0..<room])
            capped = true
        } else {
            buffer.append(contentsOf: mono)
        }
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return buffer.count }
    var isCapped: Bool { lock.lock(); defer { lock.unlock() }; return capped }
    var level: Float { lock.lock(); defer { lock.unlock() }; return lastLevel }
    func drain() -> [Float] { lock.lock(); defer { lock.unlock() }; return buffer }
}

// MARK: - MicrophoneRecorder

@MainActor
final class MicrophoneRecorder {

    // MARK: Errors
    enum RecorderError: LocalizedError {
        case engineFailed(Error)

        var errorDescription: String? {
            switch self {
            case let .engineFailed(error):
                return "Couldn't start the microphone: \(error.localizedDescription)"
            }
        }
    }

    let maxSeconds: Double
    private(set) var sampleRate: Double = 44_100
    private(set) var isRecording = false

    /// Linear capture gain applied per-sample (with `tanh` saturation) before
    /// storing. macOS routes many USB condenser mics (e.g. Blue Yeti) at a low
    /// input level; ~+12 dB lets the user record at a normal distance without
    /// pegging the meter or tripping the "too quiet" feedback, and boosting
    /// before the Int16 WAV quantization preserves resolution the downstream
    /// RMS-normalization would otherwise have to lift out of the noise floor.
    private let captureGain: Float = 4.0

    private let engine = AVAudioEngine()
    private let sink = RecordingSampleSink()
    private var capFrames = 0

    init(maxSeconds: Double = 45) {
        self.maxSeconds = maxSeconds
    }

    // MARK: Permission

    /// Resolve microphone authorization, prompting once if undetermined.
    /// Mirrors `DictationController.requestAuthorization`'s device-audio check.
    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    // MARK: Capture

    func start() throws {
        let input = engine.inputNode
        // `outputFormat(forBus:)` — using `inputFormat` here trips CoreAudio
        // preconditions on some devices (same note as DictationController).
        let format = input.outputFormat(forBus: 0)
        sampleRate = format.sampleRate
        capFrames = Int(maxSeconds * sampleRate)
        sink.reset(capacity: capFrames)

        // The tap block runs on the realtime audio thread, so it MUST be
        // nonisolated. Under this module's default-MainActor isolation, a bare
        // closure written inside this @MainActor method is inferred
        // @MainActor — which makes the Swift runtime assert main-queue
        // execution and trap when the audio thread invokes it. Typing the block
        // `@Sendable` forces nonisolation; it captures only Sendable values
        // (the lock-guarded sink + cap), so the audio thread never touches
        // main-actor state.
        let theSink = sink
        let cap = capFrames
        let gain = captureGain
        let tapBlock: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
            theSink.append(buffer, cap: cap, gain: gain)
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: tapBlock)

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.engineFailed(error)
        }
        isRecording = true
    }

    /// Stop the engine and return the captured mono samples at `sampleRate`.
    @discardableResult
    func stop() -> [Float] {
        guard isRecording else { return sink.drain() }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        return sink.drain()
    }

    // MARK: Live readouts (polled by the view model)

    var currentFrameCount: Int { sink.count }
    var currentLevel: Float { sink.level }
    var reachedCap: Bool { sink.isCapped }
}
