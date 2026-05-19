//
//  OrbView.swift
//  pocket-tts-macos
//
//  Metal-backed audio-reactive orb visualization. Wraps an MTKView
//  that runs the raymarched plasma shader at 60fps, driven by
//  real-time amplitude from the StreamingPlayer.

import MetalKit
import SwiftUI
import Synchronization

// MARK: - AmplitudeRef
// Reference-type wrapper around Atomic<Float> so that SwiftUI structs and
// Metal renderers can share a single amplitude value without running into
// Swift 6's noncopyable-type restrictions on struct stored properties.

@preconcurrency
final class AmplitudeRef: @unchecked Sendable {
    nonisolated let atomic: Atomic<Float>
    nonisolated init(_ initial: Float = 0) { atomic = Atomic<Float>(initial) }
}

// MARK: - Uniform struct (must match OrbShader.metal layout)

struct OrbUniforms {
    var time: Float
    var intensity: Float
    var smoothAmp: Float
    var resolution: SIMD2<Float>
}

// MARK: - OrbRenderer

final class OrbRenderer: NSObject, MTKViewDelegate {

    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let startTime: CFTimeInterval
    private var smoothAmplitude: Float = 0
    private let amplitudeSource: AmplitudeRef

    init(device: MTLDevice, view: MTKView, amplitudeSource: AmplitudeRef) {
        self.amplitudeSource = amplitudeSource
        self.startTime = CACurrentMediaTime()

        guard let queue = device.makeCommandQueue() else {
            fatalError("Failed to create Metal command queue")
        }
        self.commandQueue = queue

        guard let library = device.makeDefaultLibrary(),
              let vertexFn = library.makeFunction(name: "orbVertex"),
              let fragmentFn = library.makeFunction(name: "orbFragment") else {
            fatalError("Failed to load Metal shader functions")
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFn
        desc.fragmentFunction = fragmentFn
        desc.colorAttachments[0].pixelFormat = view.colorPixelFormat

        // Additive blending to match the Electron renderer.
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .one
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .zero

        do {
            self.pipelineState = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            fatalError("Failed to create Metal pipeline state: \(error)")
        }

        super.init()
    }

    // MARK: - MTKViewDelegate

    func draw(in view: MTKView) {
        let rawAmp = amplitudeSource.atomic.load(ordering: .relaxed)
        smoothAmplitude += (rawAmp - smoothAmplitude) * 0.20

        var uniforms = OrbUniforms(
            time: Float((CACurrentMediaTime() - startTime) * 0.4),
            intensity: 0.2 + smoothAmplitude * 0.8,
            smoothAmp: smoothAmplitude,
            resolution: SIMD2<Float>(
                Float(view.drawableSize.width),
                Float(view.drawableSize.height)
            )
        )

        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor else { return }

        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let cb = commandQueue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }

        enc.setRenderPipelineState(pipelineState)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<OrbUniforms>.size, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        enc.endEncoding()

        cb.present(drawable)
        cb.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

// MARK: - OrbView (SwiftUI wrapper)

struct OrbView: NSViewRepresentable {
    let amplitudeSource: AmplitudeRef

    func makeNSView(context: Context) -> MTKView {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not available on this device")
        }

        let view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false

        if let srgb = CGColorSpace(name: CGColorSpace.sRGB) {
            view.colorspace = srgb
        }

        let renderer = OrbRenderer(
            device: device,
            view: view,
            amplitudeSource: amplitudeSource
        )
        view.delegate = renderer
        context.coordinator.renderer = renderer

        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var renderer: OrbRenderer?
    }
}
