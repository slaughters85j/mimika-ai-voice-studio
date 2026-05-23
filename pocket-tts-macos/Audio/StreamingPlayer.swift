//
//  StreamingPlayer.swift
//  pocket-tts-macos
//

// `@preconcurrency` downgrades Swift 6 Sendable warnings from AVFAudio
// types to nothing: Apple hasn't marked `AVAudioEngine` / `AVAudioPlayerNode`
// Sendable yet, but we capture them in the `DispatchQueue.global(...).async`
// stop-hop below (the priority-inversion guard) where they're only touched
// once before the closure returns. Matches the same opt-out used in
// Engine/VoiceChangerPipeline.swift for AVURLAsset.
@preconcurrency import AVFoundation
import Foundation
import Synchronization

// MARK: - StreamingPlayer
// Progressive playback of an AsyncStream<PCMFrame> through AVAudioEngine.
//
// Architecture:
//   PCMFrame (1920 Float32 @ 24 kHz mono, 80 ms)
//      → AVAudioPCMBuffer
//      → AVAudioPlayerNode.scheduleBuffer (gap-free wall-clock scheduling)
//      → AVAudioEngine.mainMixerNode (resamples to device format)
//      → outputNode (speakers)
//
// AVAudioEngine bridges 24 kHz mono → device-native (typically 48 kHz stereo)
// at connection time, so we don't construct an AVAudioConverter manually.
// scheduleBuffer is documented thread-safe; per-frame allocation at 12.5 Hz
// is well within budget (engine produces ~3× real-time, so the player is
// always fed ahead of the audio clock).

actor StreamingPlayer {

    // MARK: - Errors
    enum PlayerError: Error, CustomStringConvertible {
        case engineStartFailed(Error)
        case bufferAllocationFailed
        case stopped

        var description: String {
            switch self {
            case let .engineStartFailed(e): return "AVAudioEngine start failed: \(e)"
            case .bufferAllocationFailed: return "could not allocate AVAudioPCMBuffer"
            case .stopped: return "playback was stopped"
            }
        }
    }

    // MARK: - Stored state
    let currentAmplitude = AmplitudeRef(0)

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let format: AVAudioFormat

    // Drain coordination: the last scheduled buffer's completion callback fires
    // on AVAudioEngine's internal thread; we hop back into the actor to signal
    // completion. Two flags handle the race where the signal arrives before
    // `play()` sets up its continuation.
    private var drainContinuation: CheckedContinuation<Void, Error>?
    private var drainCompletedEarly = false
    private var isStopped = false

    // MARK: - Init
    init() throws {
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        ) else {
            throw PlayerError.bufferAllocationFailed
        }
        self.format = fmt

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        engine.prepare()
    }

    // MARK: - Public controls

    /// Consume the stream, scheduling each frame on the player node. Returns
    /// once the last scheduled buffer has played all the way through (i.e. the
    /// user has heard the end). On `stop()` or `Task` cancellation, throws
    /// `PlayerError.stopped` after halting the engine.
    func play(stream: AsyncStream<PCMFrame>) async throws {
        // Reset per-call state.
        isStopped = false
        drainContinuation = nil
        drainCompletedEarly = false

        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                throw PlayerError.engineStartFailed(error)
            }
        }
        playerNode.play()

        var sawFinalFlag = false

        for await frame in stream {
            if isStopped { throw PlayerError.stopped }

            let buf = try makeBuffer(samples: frame.samples)

            var sumSq: Float = 0
            for s in frame.samples { sumSq += s * s }
            let rms = (sumSq / Float(frame.samples.count)).squareRoot()
            currentAmplitude.atomic.store(min(rms * 4.0, 1.0), ordering: .relaxed)

            if frame.isFinal {
                sawFinalFlag = true
                scheduleWithDrainCallback(buf)
            } else {
                playerNode.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack, completionHandler: nil)
            }
        }

        // Stream ended without the engine ever raising `isFinal`. Schedule a
        // single-sample sentinel buffer at the tail so the drain callback
        // still fires. (Same outcome the Electron player gets when the HTTP
        // stream just closes.)
        if !sawFinalFlag {
            let sentinel = try makeBuffer(samples: [0.0])
            scheduleWithDrainCallback(sentinel)
        }

        // Wait for the tail buffer to fully play. Race-safe:
        //   * If the callback already fired (e.g. one-frame stream), resume immediately.
        //   * Otherwise, park the continuation; the callback will pick it up.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            if drainCompletedEarly {
                drainCompletedEarly = false
                cont.resume()
            } else if isStopped {
                cont.resume(throwing: PlayerError.stopped)
            } else {
                drainContinuation = cont
            }
        }
        currentAmplitude.atomic.store(0, ordering: .relaxed)
    }

    /// Hard stop: halts player + engine and unblocks any in-flight `play()`.
    /// A subsequent `play()` call will restart the engine.
    func stop() {
        isStopped = true
        currentAmplitude.atomic.store(0, ordering: .relaxed)

        // Priority-inversion guard. `playerNode.stop()` / `engine.stop()`
        // synchronously wait on AVAudioEngine's internal Default-QoS
        // threads. The actor is frequently entered from a User-initiated
        // context (stop button in SwiftUI), and blocking that thread on
        // the lower-priority audio threads trips Xcode's "Hang Risk"
        // diagnostic. Hopping the AV teardown onto a Default-QoS queue
        // matches the worker priority and clears the inversion. The
        // drain-side continuation is signaled below either way, so
        // observable timing is unchanged for callers.
        let pn = playerNode
        let eng = engine
        DispatchQueue.global(qos: .default).async {
            if pn.isPlaying { pn.stop() }
            if eng.isRunning { eng.stop() }
        }

        // Surface stop to any awaiter.
        if let cont = drainContinuation {
            drainContinuation = nil
            cont.resume(throwing: PlayerError.stopped)
        }
    }

    /// Suspends playback. Scheduled buffers are retained; `resume()` restarts.
    /// Matches the Electron streaming-wav-player.ts pause semantics.
    func pause() {
        engine.pause()
    }

    func resume() throws {
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                throw PlayerError.engineStartFailed(error)
            }
        }
        if !playerNode.isPlaying { playerNode.play() }
    }

    // MARK: - Private helpers

    /// Schedule the given buffer and attach the drain completion callback.
    /// The callback hops back into the actor to coordinate with `play()`'s
    /// continuation.
    private func scheduleWithDrainCallback(_ buf: AVAudioPCMBuffer) {
        playerNode.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { await self?.signalDrainComplete() }
        }
    }

    private func signalDrainComplete() {
        if let cont = drainContinuation {
            drainContinuation = nil
            if isStopped {
                cont.resume(throwing: PlayerError.stopped)
            } else {
                cont.resume()
            }
        } else {
            // Callback arrived before `play()` parked its continuation —
            // remember it so the await resolves immediately.
            drainCompletedEarly = true
        }
    }

    private func makeBuffer(samples: [Float]) throws -> AVAudioPCMBuffer {
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw PlayerError.bufferAllocationFailed
        }
        buf.frameLength = AVAudioFrameCount(samples.count)
        guard let channelData = buf.floatChannelData?[0] else {
            throw PlayerError.bufferAllocationFailed
        }
        samples.withUnsafeBufferPointer { src in
            channelData.update(from: src.baseAddress!, count: samples.count)
        }
        return buf
    }
}
