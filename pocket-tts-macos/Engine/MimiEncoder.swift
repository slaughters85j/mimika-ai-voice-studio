//
//  MimiEncoder.swift
//  pocket-tts-macos
//
//  Native MLX port of the Mimi audio encoder for Pocket-TTS voice encoding.
//  Converts raw audio [1, 1, N] @ 24kHz → conditioning [1, T, 1024].
//
//  Architecture (18.14M params):
//    SEANet encoder (conv stack with residual blocks, 2.93M)
//    → Encoder transformer (2 layers, 8 heads, dim=512, 6.30M)
//    → Conv downsample (200Hz → 12.5Hz, 8.39M)
//    → Speaker projection (Linear 512→1024, 0.52M)

import Foundation
import MLX
import MLXNN

// MARK: - MimiEncoder

class MimiEncoder: Module {

    // SEANet encoder layers (12 items)
    // nonisolated(unsafe) is required so that nonisolated init() can write these properties.
    // Weight key mapping is handled explicitly in load() by renaming dict keys before update().
    nonisolated(unsafe) var conv0: MLXConv1d           // in=1, out=64, k=7
    nonisolated(unsafe) var res1: MLXResBlock           // dim=64
    nonisolated(unsafe) var conv3: MLXConv1d           // in=64, out=128, k=8, s=4
    nonisolated(unsafe) var res4: MLXResBlock           // dim=128
    nonisolated(unsafe) var conv6: MLXConv1d           // in=128, out=256, k=10, s=5
    nonisolated(unsafe) var res7: MLXResBlock           // dim=256
    nonisolated(unsafe) var conv9: MLXConv1d           // in=256, out=512, k=12, s=6
    nonisolated(unsafe) var conv11: MLXConv1d         // in=512, out=512, k=3

    // Encoder transformer (2 layers)
    nonisolated(unsafe) var transformer: MimiTransformer

    // Downsample (200Hz → 12.5Hz)
    nonisolated(unsafe) var downsampleConv: MLXConv1d   // in=512, out=512, k=32, s=16

    // Speaker projection
    nonisolated(unsafe) var speakerProjWeight: MLXArray  // [1024, 512]

    nonisolated override init() {
        self.conv0 = MLXConv1d(inChannels: 1, outChannels: 64, kernelSize: 7, stride: 1)
        self.res1 = MLXResBlock(dim: 64, kernelSizes: [3, 1], dilations: [1, 1])
        self.conv3 = MLXConv1d(inChannels: 64, outChannels: 128, kernelSize: 8, stride: 4)
        self.res4 = MLXResBlock(dim: 128, kernelSizes: [3, 1], dilations: [1, 1])
        self.conv6 = MLXConv1d(inChannels: 128, outChannels: 256, kernelSize: 10, stride: 5)
        self.res7 = MLXResBlock(dim: 256, kernelSizes: [3, 1], dilations: [1, 1])
        self.conv9 = MLXConv1d(inChannels: 256, outChannels: 512, kernelSize: 12, stride: 6)
        self.conv11 = MLXConv1d(inChannels: 512, outChannels: 512, kernelSize: 3, stride: 1)
        self.transformer = MimiTransformer(dim: 512, numHeads: 8, numLayers: 2, ffnDim: 2048)
        self.downsampleConv = MLXConv1d(inChannels: 512, outChannels: 512, kernelSize: 32, stride: 16, padMode: "replicate")
        self.speakerProjWeight = MLXArray.zeros([1024, 512])
        super.init()
    }

    nonisolated func encode(_ audio: MLXArray, debug: Bool = false) -> MLXArray {
        // audio: [1, 1, N] → channels-last [1, N, 1] for MLX conv
        var x = audio.transposed(0, 2, 1)

        // pad_for_conv1d: right-pad for frame alignment (called ONCE on raw audio)
        x = padForFrameAlignment(x, kernelSize: 1920, stride: 1920)
        if debug { logStats("after_pad", x) }

        // SEANet encoder — each conv has causal left-padding built in
        x = conv0(x);    if debug { logStats("conv0", x) }
        x = res1(x);     if debug { logStats("res1", x) }
        x = elu(x);      if debug { logStats("elu2", x) }
        x = conv3(x);    if debug { logStats("conv3", x) }
        x = res4(x);     if debug { logStats("res4", x) }
        x = elu(x);      if debug { logStats("elu5", x) }
        x = conv6(x);    if debug { logStats("conv6", x) }
        x = res7(x);     if debug { logStats("res7", x) }
        x = elu(x);      if debug { logStats("elu8", x) }
        x = conv9(x);    if debug { logStats("conv9", x) }
        x = elu(x);      if debug { logStats("elu10", x) }
        x = conv11(x);   if debug { logStats("conv11", x) }

        // Encoder transformer (channels-last [B, T, C])
        x = transformer(x)
        if debug { logStats("transformer", x) }

        // Downsample 200Hz → 12.5Hz
        x = downsampleConv(x)
        if debug { logStats("downsample", x) }

        // Speaker projection: [B, T, 512] → [B, T, 1024]
        x = MLX.matmul(x, speakerProjWeight.T)
        if debug { logStats("conditioning", x) }

        return x
    }

    private nonisolated func logStats(_ label: String, _ x: MLXArray) {
        eval(x)
        let data = x.asArray(Float.self)
        let mean = data.reduce(0, +) / Float(data.count)
        var sumSq: Float = 0
        for v in data { sumSq += (v - mean) * (v - mean) }
        let std = sqrt(sumSq / Float(data.count))
        print("[MimiEncoder] \(label): shape=\(x.shape), mean=\(String(format: "%.6f", mean)), std=\(String(format: "%.6f", std))")
    }

    // MARK: - Padding

    /// Right-pad to ensure total length is a multiple of frame_size (matches pad_for_conv1d).
    /// Called once on raw audio before the encoder.
    private nonisolated func padForFrameAlignment(_ x: MLXArray, kernelSize: Int, stride: Int) -> MLXArray {
        let length = x.shape[1]
        let nFrames = Double(length - kernelSize) / Double(stride) + 1.0
        let idealLength = (Int(ceil(nFrames)) - 1) * stride + kernelSize
        let extra = idealLength - length
        guard extra > 0 else { return x }
        return MLX.padded(x, widths: [IntOrPair(0), IntOrPair((0, extra)), IntOrPair(0)])
    }
}

// MARK: - MLX Conv1d (channels-last, non-streaming)

class MLXConv1d: Module {
    nonisolated(unsafe) var conv: MLXNN.Conv1d
    let causalPad: Int
    let useReplicatePad: Bool

    nonisolated override init() {
        self.conv = MLXNN.Conv1d(inputChannels: 1, outputChannels: 1, kernelSize: 1)
        self.causalPad = 0
        self.useReplicatePad = false
        super.init()
    }

    nonisolated init(inChannels: Int, outChannels: Int, kernelSize: Int, stride: Int = 1, dilation: Int = 1, padMode: String = "constant") {
        let effectiveKernel = (kernelSize - 1) * dilation + 1
        self.causalPad = effectiveKernel - stride
        self.useReplicatePad = padMode == "replicate"
        self.conv = MLXNN.Conv1d(
            inputChannels: inChannels,
            outputChannels: outChannels,
            kernelSize: kernelSize,
            stride: stride,
            dilation: dilation
        )
        super.init()
    }

    nonisolated func callAsFunction(_ x: MLXArray) -> MLXArray {
        guard causalPad > 0 else { return conv(x) }

        let padded: MLXArray
        if useReplicatePad {
            // Replicate mode: fill left padding with the first input frame
            // Matches StreamingConv1d with pad_mode="replicate" and model_state=None
            let firstFrame = x[0..., 0..<1, 0...]  // [B, 1, C]
            let repeated = MLX.repeated(firstFrame, count: causalPad, axis: 1)  // [B, causalPad, C]
            padded = concatenated([repeated, x], axis: 1)
        } else {
            // Constant (zero) mode
            padded = MLX.padded(x, widths: [IntOrPair(0), IntOrPair((causalPad, 0)), IntOrPair(0)])
        }
        return conv(padded)
    }
}

// MARK: - Residual Block

class MLXResBlock: Module {
    nonisolated(unsafe) var conv1: MLXConv1d
    nonisolated(unsafe) var conv2: MLXConv1d

    nonisolated override init() {
        self.conv1 = MLXConv1d(inChannels: 1, outChannels: 1, kernelSize: 1)
        self.conv2 = MLXConv1d(inChannels: 1, outChannels: 1, kernelSize: 1)
        super.init()
    }

    nonisolated init(dim: Int, kernelSizes: [Int], dilations: [Int], compress: Int = 2) {
        let hidden = dim / compress
        self.conv1 = MLXConv1d(inChannels: dim, outChannels: hidden, kernelSize: kernelSizes[0], dilation: dilations[0])
        self.conv2 = MLXConv1d(inChannels: hidden, outChannels: dim, kernelSize: kernelSizes[1], dilation: dilations[1])
        super.init()
    }

    nonisolated func callAsFunction(_ x: MLXArray) -> MLXArray {
        // ResBlock: ELU → Conv1 → ELU → Conv2 → residual add
        // Causal padding is handled inside each MLXConv1d
        var v = elu(x)
        v = conv1(v)
        v = elu(v)
        v = conv2(v)
        return x + v
    }
}

// MARK: - Mimi Transformer (2-layer, non-streaming)

class MimiTransformer: Module {
    nonisolated(unsafe) var layers: [MimiTransformerLayer]

    nonisolated override init() { self.layers = []; super.init() }

    nonisolated init(dim: Int, numHeads: Int, numLayers: Int, ffnDim: Int) {
        self.layers = (0..<numLayers).map { _ in
            MimiTransformerLayer(dim: dim, numHeads: numHeads, ffnDim: ffnDim)
        }
        super.init()
    }

    nonisolated func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = x
        for layer in layers {
            h = layer(h)
        }
        return h
    }
}

class MimiTransformerLayer: Module {
    nonisolated(unsafe) var inProj: Linear
    nonisolated(unsafe) var outProj: Linear
    nonisolated(unsafe) var norm1: LayerNorm
    nonisolated(unsafe) var norm2: LayerNorm
    nonisolated(unsafe) var linear1: Linear
    nonisolated(unsafe) var linear2: Linear
    nonisolated(unsafe) var layerScale1: LayerScale
    nonisolated(unsafe) var layerScale2: LayerScale
    let numHeads: Int
    let headDim: Int

    nonisolated override init() {
        self.numHeads = 1; self.headDim = 1
        self.inProj = Linear(1, 1, bias: false); self.outProj = Linear(1, 1, bias: false)
        self.norm1 = LayerNorm(dimensions: 1); self.norm2 = LayerNorm(dimensions: 1)
        self.linear1 = Linear(1, 1, bias: false); self.linear2 = Linear(1, 1, bias: false)
        self.layerScale1 = LayerScale(dim: 1); self.layerScale2 = LayerScale(dim: 1)
        super.init()
    }

    nonisolated init(dim: Int, numHeads: Int, ffnDim: Int) {
        self.numHeads = numHeads
        self.headDim = dim / numHeads
        self.inProj = Linear(dim, dim * 3, bias: false)
        self.outProj = Linear(dim, dim, bias: false)
        self.norm1 = LayerNorm(dimensions: dim)
        self.norm2 = LayerNorm(dimensions: dim)
        self.linear1 = Linear(dim, ffnDim, bias: false)
        self.linear2 = Linear(ffnDim, dim, bias: false)
        self.layerScale1 = LayerScale(dim: dim)
        self.layerScale2 = LayerScale(dim: dim)
        super.init()
    }

    nonisolated func callAsFunction(_ x: MLXArray) -> MLXArray {
        let normed = norm1(x)
        let projected = inProj(normed)  // [B, T, 3*dim]
        let dim = x.shape[2]

        let q = projected[0..., 0..., 0..<dim]
        let k = projected[0..., 0..., dim..<(2*dim)]
        let v = projected[0..., 0..., (2*dim)...]

        let B = x.shape[0]
        let T = x.shape[1]

        // Reshape to [B, T, H, D] for RoPE
        var qBTHD = q.reshaped(B, T, numHeads, headDim)
        var kBTHD = k.reshaped(B, T, numHeads, headDim)

        // RoPE (positions 0..T, offset=0 for non-streaming encoder)
        (qBTHD, kBTHD) = applyRoPE(q: qBTHD, k: kBTHD, offset: 0, maxPeriod: 10000.0)

        // Transpose to [B, H, T, D] for attention
        let qH = qBTHD.transposed(0, 2, 1, 3)
        let kH = kBTHD.transposed(0, 2, 1, 3)
        let vH = v.reshaped(B, T, numHeads, headDim).transposed(0, 2, 1, 3)

        // Causal + context mask: position i can attend to positions max(0, i-context+1)..i
        // Matches Python's delta-based mask with context=250
        let context = 250
        let posQ = MLXArray(Array(0..<T)).reshaped(1, 1, T, 1)  // [1, 1, T, 1]
        let posK = MLXArray(Array(0..<T)).reshaped(1, 1, 1, T)  // [1, 1, 1, T]
        let delta = posQ - posK
        let geZero = delta .>= 0
        let ltContext = delta .< MLXArray(context)
        let causalMask = geZero * ltContext  // element-wise AND via multiplication of bool arrays
        let maskBias = MLX.where(causalMask, MLXArray(Float(0)), MLXArray(Float(-1e9)))

        let scale = MLXArray(Float(1.0 / sqrt(Float(headDim))))
        let scores = MLX.matmul(qH, kH.transposed(0, 1, 3, 2)) * scale + maskBias
        let attnWeights = softmax(scores, axis: -1)
        let attnOut = MLX.matmul(attnWeights, vH)
            .transposed(0, 2, 1, 3)
            .reshaped(B, T, dim)

        let attnProjected = outProj(attnOut)
        var h = x + layerScale1(attnProjected)

        let ffn = linear2(gelu(linear1(norm2(h))))
        h = h + layerScale2(ffn)

        return h
    }
}

// MARK: - Layer Scale

class LayerScale: Module {
    nonisolated(unsafe) var scale: MLXArray

    nonisolated override init() { self.scale = MLXArray.ones([1]); super.init() }

    nonisolated init(dim: Int) {
        self.scale = MLXArray.ones([dim])
        super.init()
    }

    nonisolated func callAsFunction(_ x: MLXArray) -> MLXArray {
        x * scale
    }
}

// MARK: - Helpers

/// RoPE: interleaved pairs (d0,d1), (d2,d3), ... matching pocket-tts convention.
/// q, k: [B, T, H, D]
private nonisolated func applyRoPE(q: MLXArray, k: MLXArray, offset: Int, maxPeriod: Float) -> (MLXArray, MLXArray) {
    let D = q.shape[3]
    let T = q.shape[1]
    let half = D / 2

    // Frequencies
    let ds = MLXArray(Array(stride(from: Float(0), to: Float(half), by: 1)))
    let freqs = exp(ds * MLXArray(-log(maxPeriod) * 2.0 / Float(D)))  // [half]

    // Positions
    let ts = MLXArray(Array(stride(from: Float(offset), to: Float(offset + T), by: 1)))
        .reshaped(T, 1, 1)  // [T, 1, 1] broadcasts against [half]

    let cosVals = cos(freqs * ts)  // [T, 1, half]
    let sinVals = sin(freqs * ts)

    // Split into interleaved pairs: [..., D] → [..., D/2, 2]
    let qPair = q.reshaped(q.shape[0], T, q.shape[2], half, 2)
    let kPair = k.reshaped(k.shape[0], T, k.shape[2], half, 2)

    let qr = qPair[0..., 0..., 0..., 0..., 0]  // real
    let qi = qPair[0..., 0..., 0..., 0..., 1]  // imag
    let kr = kPair[0..., 0..., 0..., 0..., 0]
    let ki = kPair[0..., 0..., 0..., 0..., 1]

    let qor = qr * cosVals - qi * sinVals
    let qoi = qr * sinVals + qi * cosVals
    let kor = kr * cosVals - ki * sinVals
    let koi = kr * sinVals + ki * cosVals

    let qOut = stacked([qor, qoi], axis: -1).reshaped(q.shape)
    let kOut = stacked([kor, koi], axis: -1).reshaped(k.shape)

    return (qOut, kOut)
}

private nonisolated func elu(_ x: MLXArray, alpha: Float = 1.0) -> MLXArray {
    MLX.where(x .> 0, x, MLXArray(alpha) * (exp(x) - 1))
}

// MARK: - Loading

extension MimiEncoder {
    nonisolated static func load() throws -> MimiEncoder {
        let model = MimiEncoder()

        guard let url = Bundle.main.url(forResource: "mimi_encoder_weights", withExtension: "safetensors") else {
            throw NSError(domain: "MimiEncoder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "mimi_encoder_weights.safetensors not found in bundle"])
        }

        var weights = try MLX.loadArrays(url: url)

        // Transpose Conv1d weights from PyTorch (out, in, k) to MLX (out, k, in)
        for (key, value) in weights {
            if key.contains(".weight") && value.ndim == 3 {
                weights[key] = value.transposed(0, 2, 1)
            }
        }

        // speaker_proj_weight is a standalone weight, not a module
        let spw = weights.removeValue(forKey: "speaker_proj_weight")

        // Remap PyTorch weight keys to match Swift property names.
        // @ModuleInfo was replaced with nonisolated(unsafe) stored properties, so MLX Module
        // reflection uses the Swift property name, not an explicit key. We rekey the weight
        // dict so the names match the property / sub-module structure expected by update().
        let keyMap: [String: String] = [
            "encoder.model.0": "conv0",
            "encoder.model.1": "res1",
            "encoder.model.3": "conv3",
            "encoder.model.4": "res4",
            "encoder.model.6": "conv6",
            "encoder.model.7": "res7",
            "encoder.model.9": "conv9",
            "encoder.model.11": "conv11",
            "encoder_transformer.transformer": "transformer",
            "downsample.conv": "downsampleConv",
            // MLXResBlock children used @ModuleInfo keys "block.1" / "block.3" → now "conv1"/"conv2"
            "block.1": "conv1",
            "block.3": "conv2",
            // MLXConv1d child "@ModuleInfo(key: "conv")" → now plain "conv"
            // MimiTransformer "@ModuleInfo(key: "layers")" → now "layers"
            // MimiTransformerLayer keys:
            "self_attn.in_proj": "inProj",
            "self_attn.out_proj": "outProj",
            "layer_scale_1": "layerScale1",
            "layer_scale_2": "layerScale2",
            // LayerScale "@ModuleInfo(key: "scale")" → now "scale" (same name, no remap needed)
        ]

        // Sort by longest key first to prevent "encoder.model.1" matching "encoder.model.11"
        let sortedMap = keyMap.sorted { $0.key.count > $1.key.count }

        var remapped: [String: MLXArray] = [:]
        for (key, value) in weights {
            var newKey = key
            // Apply ALL matching remaps (don't break early — a key like
            // "encoder.model.7.block.1.conv.weight" needs both
            // "encoder.model.7"→"res7" AND "block.1"→"conv1")
            for (old, new) in sortedMap {
                // Replace as a complete dot-delimited path component
                let components = newKey.split(separator: ".").map(String.init)
                var result: [String] = []
                var i = 0
                let oldParts = old.split(separator: ".").map(String.init)
                while i < components.count {
                    // Check if components[i..] starts with oldParts
                    if i + oldParts.count <= components.count {
                        let slice = Array(components[i..<(i + oldParts.count)])
                        if slice == oldParts {
                            result.append(contentsOf: new.split(separator: ".").map(String.init))
                            i += oldParts.count
                            continue
                        }
                    }
                    result.append(components[i])
                    i += 1
                }
                newKey = result.joined(separator: ".")
            }
            remapped[newKey] = value
        }

        try model.update(parameters: ModuleParameters.unflattened(remapped), verify: .noUnusedKeys)

        if let spw {
            model.speakerProjWeight = spw
        }

        eval(model)
        print("[MimiEncoder] loaded \(weights.count) weight tensors")
        return model
    }
}
