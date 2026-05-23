//
//  PocketTTSVoiceEncoder.swift
//  pocket-tts-macos
//
//  Encodes a WAV file into Pocket-TTS KV cache states (safetensors).
//  Pipeline: WAV → MimiEncoder (MLX) → voice_prompt_phase (Core ML) → safetensors.
//
//  The output safetensors matches the format of the bundled voice files
//  in Resources/voice_kv_states/ and can be loaded by VoiceLoader.

@preconcurrency import AVFoundation
// @preconcurrency: MLModel (and the MLState handle threaded through `phase`)
// are non-Sendable. Storage is `nonisolated(unsafe)` and all access is
// serialised by the actor (see comment at the voicePhaseModel property), but
// Swift 6 still flags the send of `phase` across the prediction `await`.
// @preconcurrency tells the compiler to treat this module as pre-Swift-6.
@preconcurrency import CoreML
import Foundation
import MLX

// MARK: - PocketTTSVoiceEncoder

actor PocketTTSVoiceEncoder {

    static let shared = PocketTTSVoiceEncoder()

    enum EncoderError: Error, CustomStringConvertible {
        case modelNotFound(String)
        case encodeFailed(String)

        var description: String {
            switch self {
            case .modelNotFound(let m): return "Core ML model not found: \(m)"
            case .encodeFailed(let m): return "Voice encode failed: \(m)"
            }
        }
    }

    enum Status: Equatable {
        case idle, loading, ready, encoding, error(String)
    }

    // Constants matching the conversion scripts
    private static let sampleRate = 24_000
    private static let maxSeconds = 15
    private static let tVoiceMax = 200
    private static let nLayers = 6
    private static let nHeads = 16
    private static let dHead = 64
    private static let maxSeq = 512

    private(set) var status: Status = .idle
    // nonisolated(unsafe): neither MimiEncoder (holds MLXArrays) nor MLModel conform to Sendable.
    // Both are stored and accessed exclusively within the actor's serial context; no external sharing.
    nonisolated(unsafe) private var mimiEncoder: MimiEncoder?
    nonisolated(unsafe) private var voicePhaseModel: MLModel?

    // MARK: - Bootstrap

    func bootstrap() async {
        guard status == .idle else { return }
        status = .loading
        do {
            // Load MimiEncoder (MLX-native).  We call through the nonisolated helper so that
            // the MimiEncoder instance (which holds non-Sendable MLXArrays) never crosses an
            // actor boundary — it is created and stored entirely on the actor's executor.
            try loadMimiEncoder()
            let encoder = mimiEncoder  // already set; just confirm it's present

            _ = encoder  // silence unused-variable warning

            // Load voice_prompt_phase (Core ML)
            let cuNoANE = MLModelConfiguration()
            cuNoANE.computeUnits = .cpuAndGPU
            let phaseURL = try Self.bundleURL(forResource: "voice_prompt_phase", withExtension: "mlmodelc")
            self.voicePhaseModel = try MLModel(contentsOf: phaseURL, configuration: cuNoANE)

            status = .ready
            print("[PocketTTSVoiceEncoder] models loaded (MimiEncoder + voice_prompt_phase)")
        } catch {
            status = .error(String(describing: error))
            print("[PocketTTSVoiceEncoder] bootstrap failed: \(error)")
        }
    }

    // MARK: - Unload

    func unloadModels() {
        mimiEncoder = nil
        voicePhaseModel = nil
        MLX.Memory.clearCache()
        print("[PocketTTSVoiceEncoder] models released, MLX cache cleared")
    }

    // MARK: - nonisolated MLX helpers

    /// Load MimiEncoder weights and store into `mimiEncoder`.  Must be called from within the actor.
    private nonisolated func loadMimiEncoder() throws {
        mimiEncoder = try MimiEncoder.load()
    }

    /// Run MimiEncoder on `samples` and copy the result into a pre-allocated MLMultiArray.
    /// All MLXArray work happens inside this nonisolated function so values never cross actor boundaries.
    private nonisolated func runMimiEncoder(
        samples: [Float],
        maxFrames tVoiceMax: Int
    ) throws -> (condArr: MLMultiArray, framesToCopy: Int) {
        guard let encoder = mimiEncoder else {
            throw EncoderError.modelNotFound("MimiEncoder not loaded")
        }
        // RMS normalize to -16 dB (matches Python _encode_audio's _normalize_audio_rms)
        let normalized = Self.rmsNormalize(samples, targetDB: -16.0)
        let audioMLX = MLXArray(normalized).reshaped(1, 1, normalized.count)
        let conditioning = encoder.encode(audioMLX, debug: true)
        eval(conditioning)
        let tFrames = conditioning.shape[1]
        let condData0 = conditioning.asArray(Float.self)
        let mean = condData0.reduce(0, +) / Float(condData0.count)
        var sumSq: Float = 0
        for v in condData0 { sumSq += (v - mean) * (v - mean) }
        let std = sqrt(sumSq / Float(condData0.count))
        let hasNaN = condData0.contains { $0.isNaN }
        let hasInf = condData0.contains { $0.isInfinite }
        print("[PocketTTSVoiceEncoder] MimiEncoder → \(tFrames) frames, mean=\(mean), std=\(std), NaN=\(hasNaN), Inf=\(hasInf)")

        let framesToCopy = min(tFrames, tVoiceMax)
        let condArr = try MLMultiArray(shape: [1, tVoiceMax as NSNumber, 1024], dataType: .float32)
        let condData = conditioning.asArray(Float.self)
        let condDst = condArr.dataPointer.assumingMemoryBound(to: Float.self)
        _ = condData.withUnsafeBufferPointer { src in
            memcpy(condDst, src.baseAddress!, min(condData.count, framesToCopy * 1024) * MemoryLayout<Float>.size)
        }
        return (condArr, framesToCopy)
    }

    // MARK: - Encode voice

    func encodeVoice(wavURL: URL, outputURL: URL) async throws {
        guard mimiEncoder != nil, let phase = voicePhaseModel else {
            throw EncoderError.modelNotFound("Call bootstrap() first")
        }

        status = .encoding

        // Step 1: Load audio → [Float]
        let samples = try Self.loadAudio(url: wavURL)
        print("[PocketTTSVoiceEncoder] loaded \(samples.count) samples @ 24kHz")

        // Step 2 + 3: Run MimiEncoder (MLX) → padded MLMultiArray.
        // All MLX types are created and consumed inside the nonisolated helper; no MLXArray
        // crosses the actor boundary.
        let (condArr, framesToCopy) = try runMimiEncoder(samples: samples, maxFrames: Self.tVoiceMax)

        // Step 4: Run voice_prompt_phase (Core ML) → KV cache
        let lengthArr = try MLMultiArray(shape: [1], dataType: .int32)
        lengthArr.dataPointer.assumingMemoryBound(to: Int32.self).pointee = Int32(framesToCopy)

        let phaseState = phase.makeState()
        let phaseInput = try MLDictionaryFeatureProvider(dictionary: [
            "conditioning": condArr,
            "voice_length": lengthArr,
        ])
        _ = try await phase.prediction(from: phaseInput, using: phaseState)

        // Step 5: Extract KV cache → safetensors
        try saveKVState(state: phaseState, tVoice: framesToCopy, outputURL: outputURL)

        // Release models from memory — they're not needed after encoding
        unloadModels()

        status = .idle  // reset to idle so bootstrap() can reload if needed later
        print("[PocketTTSVoiceEncoder] saved KV state → \(outputURL.lastPathComponent) (T_voice=\(framesToCopy)), models unloaded")
    }

    // MARK: - Audio loading

    private nonisolated static func loadAudio(url: URL) throws -> [Float] {
        do {
            return try AudioPreconditioner.loadMonoFloat32(
                url: url,
                targetRate: sampleRate,
                maxSeconds: Double(maxSeconds)
            )
        } catch {
            throw EncoderError.encodeFailed(String(describing: error))
        }
    }

    private nonisolated static func rmsNormalize(_ samples: [Float], targetDB: Float) -> [Float] {
        var sumSq: Float = 0
        for s in samples { sumSq += s * s }
        let rms = sqrt(sumSq / Float(samples.count))
        guard rms > 1e-8 else { return samples }
        let targetRMS = pow(10, targetDB / 20.0)
        let gain = targetRMS / rms
        return samples.map { min(max($0 * gain, -1.0), 1.0) }
    }

    // MARK: - KV state output

    private func saveKVState(state: MLState, tVoice: Int, outputURL: URL) throws {
        var kvData: [String: [Float16]] = [:]
        let bufferSize = Self.maxSeq * Self.nHeads * Self.dHead

        for i in 0..<Self.nLayers {
            var kBuf = [Float16](repeating: 0, count: bufferSize)
            state.withMultiArray(for: "kv_k_\(i)") { arr in
                let src = arr.dataPointer.assumingMemoryBound(to: Float16.self)
                kBuf = Array(UnsafeBufferPointer(start: src, count: bufferSize))
            }
            kvData["kv_k_\(i)"] = kBuf

            var vBuf = [Float16](repeating: 0, count: bufferSize)
            state.withMultiArray(for: "kv_v_\(i)") { arr in
                let src = arr.dataPointer.assumingMemoryBound(to: Float16.self)
                vBuf = Array(UnsafeBufferPointer(start: src, count: bufferSize))
            }
            kvData["kv_v_\(i)"] = vBuf
        }

        try writeSafetensors(kvData: kvData, tVoice: tVoice, to: outputURL)
    }

    private func writeSafetensors(kvData: [String: [Float16]], tVoice: Int, to url: URL) throws {
        let shape = [1, Self.maxSeq, Self.nHeads, Self.dHead]
        let bytesPerTensor = shape.reduce(1, *) * MemoryLayout<Float16>.size
        let sortedKeys = kvData.keys.sorted()

        var headerDict: [String: Any] = [:]
        var offset = 0
        for key in sortedKeys {
            headerDict[key] = [
                "dtype": "F16",
                "shape": shape,
                "data_offsets": [offset, offset + bytesPerTensor],
            ] as [String: Any]
            offset += bytesPerTensor
        }

        let meta: [String: Any] = [
            "T_voice": tVoice,
            "n_layers": Self.nLayers,
            "n_heads": Self.nHeads,
            "d_head": Self.dHead,
            "max_seq": Self.maxSeq,
            "dtype": "float16",
        ]
        let metaJSON = try JSONSerialization.data(withJSONObject: meta)
        headerDict["__metadata__"] = ["info": String(data: metaJSON, encoding: .utf8)!]

        let headerData = try JSONSerialization.data(withJSONObject: headerDict)

        var fileData = Data()
        var headerLen = UInt64(headerData.count)
        fileData.append(Data(bytes: &headerLen, count: 8))
        fileData.append(headerData)
        for key in sortedKeys {
            guard let buf = kvData[key] else { continue }
            buf.withUnsafeBufferPointer { ptr in
                fileData.append(UnsafeBufferPointer(start: ptr.baseAddress, count: buf.count))
            }
        }

        try fileData.write(to: url, options: .atomic)
    }

    // MARK: - Bundle helpers

    private nonisolated static func bundleURL(forResource name: String, withExtension ext: String) throws -> URL {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
            throw EncoderError.modelNotFound("\(name).\(ext) not in bundle")
        }
        return url
    }
}
