//
//  StreamingPlayer.swift
//  mimika-ai-voice-studio
//

// `@preconcurrency` downgrades Swift 6 Sendable warnings from AVFAudio
// types to nothing: Apple hasn't marked `AVAudioEngine` / `AVAudioPlayerNode`
// Sendable yet, but we capture them in the `controlQueue` hops below (the
// priority-inversion guard — see `controlQueue`), where the engine is only
// ever driven from that one serial queue. Matches the same opt-out used in
// Engine/VoiceChangerPipeline.swift for AVURLAsset.
@preconcurrency import AVFoundation
#if os(macOS)
import CoreAudio
#endif
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

    // `engine` and `playerNode` are `internal` (not `private`) so the
    // output-route-following logic in StreamingPlayer+Routing.swift can
    // rebind/restart them. Nothing outside this actor touches them.
    let engine = AVAudioEngine()
    let playerNode = AVAudioPlayerNode()
    private let format: AVAudioFormat

    // Drain coordination: the last scheduled buffer's completion callback fires
    // on AVAudioEngine's internal thread; we hop back into the actor to signal
    // completion. Two flags handle the race where the signal arrives before
    // `play()` sets up its continuation.
    private var drainContinuation: CheckedContinuation<Void, Error>?
    private var drainCompletedEarly = false
    private(set) var isStopped = false

    /// Serial queue for blocking AVAudioEngine lifecycle calls (start / stop /
    /// pause / setDeviceID). The queue carries NO fixed QoS, so each work item
    /// runs at the QoS of whatever submits it:
    ///
    ///   * AWAITED hops (`startEngineAndPlayer`, `rebindOutputDevice`) submit a
    ///     plain `async` block, which inherits the calling actor's QoS. Caller
    ///     and work item then share a QoS, so a high-QoS task never sits blocked
    ///     on lower-QoS work — which is the priority inversion the Thread
    ///     Performance Checker flags. (An earlier version pinned these at
    ///     `.default` with `.enforceQoS`. That flag FORBIDS the priority boost,
    ///     so it *guaranteed* the inversion whenever a `user-initiated` caller
    ///     awaited the hop — confirmed by a QoS trace: caller 25, block 21.
    ///     Suspending the actor via continuation does NOT break the QoS
    ///     wait-for edge; the runtime still sees 25 waiting on 21.)
    ///
    ///   * The FIRE-AND-FORGET teardown (`stopEngineAndPlayer`) still pins
    ///     itself at `.default` with `.enforceQoS`: nobody awaits it, so there's
    ///     no inversion, and pinning keeps `AVAudioEngine.stop()`'s internal
    ///     `CancelTimer` off a high-QoS thread.
    private let controlQueue = DispatchQueue(
        label: "com.slaughtersj.mimika-ai-voice-studio.streamingplayer.control"
    )

    // MARK: - Output-route following
    // macOS AVAudioEngine binds its output to whatever device is the system
    // default when the output node is first realized, and does NOT migrate
    // when the default changes afterward (AirPods connecting, the user
    // switching outputs, a display's speakers waking, etc.). We explicitly
    // bind the engine's output to the current default and re-bind on every
    // default-device / configuration change so Mimika follows the system
    // output like every other app. Logic lives in StreamingPlayer+Routing.swift.

    /// Serial queue the CoreAudio default-output-device listener fires on.
    let routeQueue = DispatchQueue(label: "com.slaughtersj.mimika-ai-voice-studio.streamingplayer.route")

    /// Owns the route-change observers; its own plain-class `deinit` removes
    /// them when this player is released. (An actor's nonisolated `deinit`
    /// can't touch non-Sendable isolated state, so teardown lives in the
    /// token — see RouteObserverToken in StreamingPlayer+Routing.swift.)
    var routeObserverToken: RouteObserverToken?

    /// True while `play()` is actively consuming a stream + draining. Route
    /// changes that land mid-utterance are deferred (`pendingReroute`) until
    /// the short utterance finishes, so we never stop the engine underneath
    /// an in-flight drain continuation.
    var isStreaming = false
    var pendingReroute = false

    /// One-time guard so the route observers are installed on first playback
    /// rather than in `init` — an actor's synchronous initializer can't call
    /// isolated methods. Binding to the current default still happens on every
    /// `play()` / `resume()` via `applyCurrentDefaultOutputDevice()`.
    var routingConfigured = false

    #if os(macOS)
    /// Output device the engine is currently bound to — lets us skip a
    /// needless stop/rebind when the default hasn't actually changed.
    var boundDeviceID: AudioDeviceID = 0
    #endif

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
        isStreaming = true
        pendingReroute = false
        defer { isStreaming = false }

        // Install route observers once, then make sure this utterance plays on
        // whatever output is the current system default (cheap no-op when it
        // hasn't changed since last time).
        configureOutputRouting()
        await applyCurrentDefaultOutputDevice()

        try await startEngineAndPlayer()

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

        // A route change that arrived mid-utterance was deferred; apply it now
        // that the drain is complete, so the next utterance lands on the right
        // device.
        if pendingReroute {
            pendingReroute = false
            await applyCurrentDefaultOutputDevice(restartIfNeeded: true)
        }
    }

    /// Hard stop: halts player + engine and unblocks any in-flight `play()`.
    /// A subsequent `play()` call will restart the engine.
    func stop() {
        isStopped = true
        currentAmplitude.atomic.store(0, ordering: .relaxed)

        // Tear down on the control queue (fire-and-forget). `.enforceQoS`
        // pins the work at the queue's `.default` QoS — matching AVFoundation's
        // internal timer queue — so the caller's (often `.userInitiated`) QoS
        // can't propagate in and leave a high-QoS thread blocked inside
        // `AVAEDispatchQueueTimer::CancelTimer`. That propagation is exactly
        // what the earlier `DispatchQueue.global(qos: .default).async` form
        // missed, and what the Thread Performance Checker kept flagging.
        stopEngineAndPlayer()

        // Surface stop to any awaiter.
        if let cont = drainContinuation {
            drainContinuation = nil
            cont.resume(throwing: PlayerError.stopped)
        }
    }

    /// Suspends playback. Scheduled buffers are retained; `resume()` restarts.
    /// Matches the Electron streaming-wav-player.ts pause semantics.
    func pause() async {
        let eng = engine
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            controlQueue.async(qos: .default, flags: .enforceQoS) {
                eng.pause()
                cont.resume()
            }
        }
    }

    func resume() async throws {
        // Install route observers once, re-bind to the current default output
        // in case it changed while paused, then restart on the control queue.
        configureOutputRouting()
        await applyCurrentDefaultOutputDevice()
        try await startEngineAndPlayer()
    }

    // MARK: - Engine lifecycle (control queue)

    /// Start the engine + player node on the control queue, awaited. Throws
    /// `PlayerError.engineStartFailed` if the engine won't start.
    private func startEngineAndPlayer() async throws {
        let eng = engine
        let pn = playerNode
        // Plain `async` (no qos / no .enforceQoS): the block inherits the
        // awaiting actor's QoS, so the awaiter never blocks on lower-QoS work.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            controlQueue.async {
                do {
                    if !eng.isRunning { try eng.start() }
                    if !pn.isPlaying { pn.play() }
                    cont.resume()
                } catch {
                    cont.resume(throwing: PlayerError.engineStartFailed(error))
                }
            }
        }
    }

    /// Stop the player node + engine on the control queue. Fire-and-forget:
    /// `stop()` doesn't need to await teardown, and not awaiting keeps the
    /// caller's thread free.
    private func stopEngineAndPlayer() {
        let pn = playerNode
        let eng = engine
        controlQueue.async(qos: .default, flags: .enforceQoS) {
            if pn.isPlaying { pn.stop() }
            if eng.isRunning { eng.stop() }
        }
    }

    #if os(macOS)
    /// Re-bind the engine's output to `deviceID` on the control queue
    /// (awaited). AVAudioEngine only allows the output device to change while
    /// stopped, so the engine is stopped, re-pointed, and — when `restart` is
    /// set — restarted, all on the one serial queue. Returns the device it
    /// bound to, or nil if `setDeviceID` failed. Called by the route-following
    /// code in StreamingPlayer+Routing.swift.
    func rebindOutputDevice(
        to deviceID: AudioDeviceID,
        wasRunning: Bool,
        restart: Bool
    ) async -> AudioDeviceID? {
        let eng = engine
        let pn = playerNode
        // Plain `async` (no qos / no .enforceQoS): inherits the awaiting actor's
        // QoS so the awaiter never blocks on lower-QoS work. (On first playback
        // `wasRunning` is false, so no `eng.stop()` runs here; mid-session
        // re-binds are driven from the route-change Task, not a high-QoS caller.)
        return await withCheckedContinuation { (cont: CheckedContinuation<AudioDeviceID?, Never>) in
            controlQueue.async {
                if wasRunning { eng.stop() }
                var bound: AudioDeviceID?
                do {
                    try eng.outputNode.auAudioUnit.setDeviceID(deviceID)
                    bound = deviceID
                } catch {
                    #if DEBUG
                    print("[StreamingPlayer] setDeviceID(\(deviceID)) failed: \(error)")
                    #endif
                }
                if restart {
                    do {
                        try eng.start()
                        if !pn.isPlaying { pn.play() }
                    } catch {
                        #if DEBUG
                        print("[StreamingPlayer] restart after reroute failed: \(error)")
                        #endif
                    }
                }
                cont.resume(returning: bound)
            }
        }
    }
    #endif

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
