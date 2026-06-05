//
//  StreamingPlayer+Routing.swift
//  mimika-ai-voice-studio
//
//  Output-device route following for StreamingPlayer.
//
//  macOS AVAudioEngine binds its output node to the system default output
//  device at the moment the node is first realized, and does NOT migrate when
//  the default changes afterward — so an engine started against the built-in
//  speakers stays silent once you put on AirPods, even though every other app
//  follows the switch. (Ordinary apps render through the CoreAudio HAL default
//  device, which the OS re-routes automatically; AVAudioEngine makes the app
//  do it.) These helpers explicitly bind the engine to the *current* default
//  and re-bind on every default-device / configuration change so Mimika
//  behaves like the rest of the system.
//

@preconcurrency import AVFoundation
import Foundation
#if os(macOS)
import CoreAudio
#endif

// MARK: - RouteObserverToken
// Owns the route-change observers and removes them in its own (plain, non-
// isolated) `deinit`. StreamingPlayer is an actor, and an actor's nonisolated
// deinit can't access non-Sendable isolated stored properties (the CoreAudio
// listener block, the NotificationCenter token) — so the teardown lives here
// instead. Released automatically when the owning StreamingPlayer is freed.
// `nonisolated` opts the class out of this module's default MainActor
// isolation so the StreamingPlayer actor can construct it synchronously.
nonisolated final class RouteObserverToken: @unchecked Sendable {
    private let notificationObserver: NSObjectProtocol?
    #if os(macOS)
    private let coreAudioBlock: AudioObjectPropertyListenerBlock?
    private let coreAudioQueue: DispatchQueue
    #endif

    #if os(macOS)
    init(
        notificationObserver: NSObjectProtocol?,
        coreAudioBlock: AudioObjectPropertyListenerBlock?,
        coreAudioQueue: DispatchQueue
    ) {
        self.notificationObserver = notificationObserver
        self.coreAudioBlock = coreAudioBlock
        self.coreAudioQueue = coreAudioQueue
    }
    #else
    init(notificationObserver: NSObjectProtocol?) {
        self.notificationObserver = notificationObserver
    }
    #endif

    deinit {
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        #if os(macOS)
        if let block = coreAudioBlock {
            var address = StreamingPlayer.defaultOutputAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                coreAudioQueue,
                block
            )
        }
        #endif
    }
}

extension StreamingPlayer {

    // MARK: - Setup (called once, lazily, on first playback)

    /// Install the listeners that keep the engine following the system default
    /// output. Idempotent — runs on the first `play()` / `resume()` rather than
    /// in `init`, because an actor's synchronous initializer can't call
    /// isolated methods. Device binding itself happens per-utterance in
    /// `applyCurrentDefaultOutputDevice()`.
    func configureOutputRouting() {
        guard !routingConfigured else { return }
        routingConfigured = true
        installRouteObservers()
    }

    // MARK: - Device binding

    /// Point the engine's output node at the current system default output
    /// device. AVAudioEngine only allows the output device to change while
    /// stopped, so a running engine is briefly stopped to re-bind and — when
    /// `restartIfNeeded` is set — restarted. A cheap no-op when the engine is
    /// already bound to the current default.
    func applyCurrentDefaultOutputDevice(restartIfNeeded: Bool = false) async {
        #if os(macOS)
        guard let deviceID = Self.currentDefaultOutputDeviceID() else { return }

        // Already on the current default — nothing to do.
        if deviceID == boundDeviceID,
           engine.outputNode.auAudioUnit.deviceID == deviceID {
            return
        }

        // The actual stop → setDeviceID → (restart) runs on the engine control
        // queue (see `rebindOutputDevice`) so it never blocks a high-QoS
        // thread. Here on the actor we only read cheap, non-blocking engine
        // state to decide what to do.
        let wasRunning = engine.isRunning
        let restart = restartIfNeeded && wasRunning && !isStopped
        if let bound = await rebindOutputDevice(to: deviceID, wasRunning: wasRunning, restart: restart) {
            boundDeviceID = bound
        }
        #endif
    }

    // MARK: - Route observation

    /// Install both route-change signals:
    ///   * `.AVAudioEngineConfigurationChange` — the bound device's format was
    ///     invalidated or the device went away (cross-platform).
    ///   * CoreAudio `kAudioHardwarePropertyDefaultOutputDevice` — the user (or
    ///     the system) picked a different default output (macOS only).
    func installRouteObservers() {
        // A Sendable thunk that re-enters the actor. The observer blocks
        // capture *this* (a Sendable closure) rather than `self` directly,
        // which keeps them out of the actor's isolation region and satisfies
        // the `sending`-parameter checks on the C callback APIs.
        let onChange: @Sendable () -> Void = { [weak self] in
            Task { await self?.handleRouteChange() }
        }

        let notificationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { _ in onChange() }

        #if os(macOS)
        var address = Self.defaultOutputAddress
        let listener: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            routeQueue,
            listener
        )
        if status != noErr {
            #if DEBUG
            print("[StreamingPlayer] default-output listener install failed: \(status)")
            #endif
        }
        routeObserverToken = RouteObserverToken(
            notificationObserver: notificationObserver,
            coreAudioBlock: status == noErr ? listener : nil,
            coreAudioQueue: routeQueue
        )
        #else
        routeObserverToken = RouteObserverToken(notificationObserver: notificationObserver)
        #endif
    }

    /// React to a default-device / configuration change. Deferred until the
    /// current short utterance finishes (see `isStreaming`) so an in-flight
    /// drain continuation is never stopped out from under `play()`.
    func handleRouteChange() async {
        guard !isStreaming else {
            pendingReroute = true
            return
        }
        await applyCurrentDefaultOutputDevice(restartIfNeeded: true)
    }

    // MARK: - CoreAudio helpers

    #if os(macOS)
    /// Property address for the system default output device.
    static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// Current system default output device, or nil if it can't be read.
    static func currentDefaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = defaultOutputAddress
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }
    #endif
}
