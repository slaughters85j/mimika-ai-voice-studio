//
//  TTSEngine.swift
//  pocket-tts-macos
//

import CoreML
import Foundation

// MARK: - PCMFrame
/// 80 ms of mono PCM @ 24 kHz (1920 samples). The unit Mimi emits per
/// autoregressive step. Phase 1's StreamingPlayer will consume these directly.
nonisolated struct PCMFrame: Sendable {
    let samples: [Float]
    let isFinal: Bool
}

// MARK: - SynthesisOptions
/// Phase 0c default values match the pocket-tts Python reference for the
/// validated test phrase. The conversion project's `e2e_python.py` runs at these.
nonisolated struct SynthesisOptions: Sendable {
    var maxFrames: Int = 256
    var framesAfterEOS: Int = 1
    var temperature: Float = 0.6
    var noiseClamp: Float = 4.0

    init() {}
}

// MARK: - TTSEngineError
enum TTSEngineError: Error, CustomStringConvertible {
    case voiceNotFound(String)
    case textOverflow(actualTokens: Int, max: Int)
    case stateBufferDtypeMismatch(name: String, actual: MLMultiArrayDataType)
    case missingOutput(String)

    var description: String {
        switch self {
        case let .voiceNotFound(id):
            return "voice id '\(id)' not in bundled catalog"
        case let .textOverflow(actual, max):
            return "encoded \(actual) tokens; prompt_phase accepts at most \(max)"
        case let .stateBufferDtypeMismatch(name, actual):
            return "state buffer \(name) has unexpected dtype \(actual); expected float16"
        case let .missingOutput(name):
            return "model output '\(name)' missing"
        }
    }
}

// MARK: - TTSEngine
/// Actor-isolated TTS pipeline. One instance per app run; lifecycle-managed by
/// whoever spawns it (in Phase 0c that's the XCTest; later, the SwiftUI shell).
actor TTSEngine {

    // MARK: Pipeline constants (must match the conversion-project scripts)
    private static let nLayers = 6
    private static let nHeads = 16
    private static let dHead = 64
    private static let maxSeq = 512
    private static let ldim = 32
    private static let tTextMax = 128
    private static let mimiOffsetPerFrame: Int32 = 16   // Mimi positions per CaLM frame
    private static let mimiPCMPerFrame = 1920           // 80 ms @ 24 kHz

    // MARK: Loaded models + assets
    private let promptModel: MLModel
    private let calmModel: MLModel
    private let mimiModel: MLModel
    private let voices: [String: LoadedVoice]
    private let tokenizer: Tokenizer

    // MARK: - Init
    init(tokenizer: Tokenizer? = nil) async throws {
        // Default to the real vendored SentencePiece tokenizer (Phase 2+3
        // upgrade from the Phase 0c FixedPhraseTokenizer). Tests can still
        // inject a FixedPhraseTokenizer for hermetic engine validation.
        self.tokenizer = try tokenizer ?? SentencePieceTokenizer()

        // Per-model compute units, matching what the conversion proved works:
        //   prompt_phase rejects ANE (multi-position SDPA → ANECompile FAILED)
        //   calm + mimi both target ALL so ANE picks up where it can
        let cuAll = MLModelConfiguration(); cuAll.computeUnits = .all
        let cuNoANE = MLModelConfiguration(); cuNoANE.computeUnits = .cpuAndGPU

        // ModelPaths returns .mlmodelc URLs — Xcode pre-compiled the packages
        // at build time, so we skip the harness's runtime MLModel.compileModel
        // step and load directly. Saves 1–3 s of cold-start.
        let promptURL = try ModelPaths.promptPhase()
        let calmURL = try ModelPaths.calmStateful()
        let mimiURL = try ModelPaths.mimiStateful()

        self.promptModel = try MLModel(contentsOf: promptURL, configuration: cuNoANE)
        self.calmModel = try MLModel(contentsOf: calmURL, configuration: cuAll)
        self.mimiModel = try MLModel(contentsOf: mimiURL, configuration: cuAll)

        // Voices: parse all bundled safetensors files into memory once. ~408 MB
        // resident; switching voices then becomes a pointer + 12 buffer writes.
        self.voices = try VoiceLoader.loadAll()
    }

    // MARK: - Public catalog
    nonisolated func availableVoiceIDs() -> [String] {
        // Read from the bundle, not the in-memory catalog, so this works before
        // init returns (e.g. UI populating a picker concurrently). Falls back to
        // an empty list if anything goes wrong; engine init will surface errors.
        (try? ModelPaths.allVoiceKVStateFiles().map { $0.deletingPathExtension().lastPathComponent }) ?? []
    }

    // MARK: - Synthesis (streaming)
    /// Streams 80 ms PCM frames as the model produces them. `nonisolated` so callers
    /// can do `for await f in engine.synthesize(...)` without an extra await hop.
    /// Errors during synthesis are logged to stderr and end the stream early.
    nonisolated func synthesize(text: String, voiceID: String, options: SynthesisOptions = SynthesisOptions()) -> AsyncStream<PCMFrame> {
        AsyncStream { continuation in
            Task {
                do {
                    try await self.runSynthesis(text: text, voiceID: voiceID, options: options, continuation: continuation)
                } catch {
                    FileHandle.standardError.write(Data("synthesize failed: \(error)\n".utf8))
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Actor-isolated synthesis pipeline
    private func runSynthesis(
        text: String,
        voiceID: String,
        options: SynthesisOptions,
        continuation: AsyncStream<PCMFrame>.Continuation
    ) throws {
        guard let voice = voices[voiceID] else {
            throw TTSEngineError.voiceNotFound(voiceID)
        }

        // 1) Tokenize.
        let (tokens, textLen) = try tokenizer.encode(text, paddedLength: Self.tTextMax)
        guard textLen <= Self.tTextMax else {
            throw TTSEngineError.textOverflow(actualTokens: textLen, max: Self.tTextMax)
        }

        // 2) Fresh states for each synthesize call (no carry-over from prior runs).
        let promptState = promptModel.makeState()
        let calmState = calmModel.makeState()
        let mimiState = mimiModel.makeState()

        // 3) Seed prompt_phase state with voice K/V (positions 0..tVoice).
        try writeVoiceKV(into: promptState, voice: voice)

        // 4) Run prompt_phase once. Side effect: positions tVoice..tVoice+tTextMax
        //    of each KV buffer get populated with text K/V.
        let tPrompt = try runPromptPhase(state: promptState, tokens: tokens, voiceOffset: voice.tVoice, textLength: textLen)

        // 5) Copy populated KV from promptState into calmState (12 buffers,
        //    direct fp16 memcpy via withMultiArray). ~60 µs total per the
        //    bandwidth estimate in the plan.
        try copyKVState(from: promptState, to: calmState)

        // 6) AR loop: CaLM → next_latent → Mimi → PCM frame → emit.
        var prevLatent = [Float](repeating: .nan, count: 1 * 1 * Self.ldim)   // BOS = NaN
        var eosStep: Int? = nil
        let loopStart = Date()
        var produced = 0

        for step in 0..<options.maxFrames {
            let frameOffset = Int32(tPrompt + step)
            let noise = sampleTruncNormal(count: Self.ldim, std: sqrt(options.temperature), clamp: options.noiseClamp)

            let (nextLatent, isEos) = try runCaLMStep(
                state: calmState,
                prevLatent: prevLatent,
                offset: frameOffset,
                noise: noise
            )

            let pcm = try runMimiStep(
                state: mimiState,
                latent: nextLatent,
                offset: Int32(step) * Self.mimiOffsetPerFrame
            )

            produced = step + 1
            let final = isEos && eosStep == nil ? false : (eosStep.map { step >= $0 + options.framesAfterEOS } ?? false)
            continuation.yield(PCMFrame(samples: pcm, isFinal: final))

            if isEos && eosStep == nil { eosStep = step }
            if let e = eosStep, step >= e + options.framesAfterEOS { break }
            prevLatent = nextLatent
        }

        let elapsed = Date().timeIntervalSince(loopStart)
        let audioSec = Double(produced * Self.mimiPCMPerFrame) / 24_000.0
        let fps = elapsed > 0 ? Double(produced) / elapsed : 0
        FileHandle.standardOutput.write(Data(String(
            format: "TTSEngine: produced %d frames, %.2fs audio in %.2fs (%.1f fps; real-time = 12.5 fps)\n",
            produced, audioSec, elapsed, fps
        ).utf8))
    }

    // MARK: - State seeding

    private func writeVoiceKV(into state: MLState, voice: LoadedVoice) throws {
        for i in 0..<Self.nLayers {
            try writeFloat16Buffer(state: state, name: "kv_k_\(i)", source: voice.kCaches[i])
            try writeFloat16Buffer(state: state, name: "kv_v_\(i)", source: voice.vCaches[i])
        }
    }

    private func copyKVState(from src: MLState, to dst: MLState) throws {
        // 12 buffers, each maxSeq * nHeads * dHead = 524288 Float16 elements = 1 MiB.
        // Use one tmp buffer per layer to avoid re-allocations across the loop.
        for i in 0..<Self.nLayers {
            try copyOneStateBuffer(name: "kv_k_\(i)", from: src, to: dst)
            try copyOneStateBuffer(name: "kv_v_\(i)", from: src, to: dst)
        }
    }

    private func copyOneStateBuffer(name: String, from src: MLState, to dst: MLState) throws {
        // Read from src, then write to dst. We don't try to share a pointer
        // across the two MLState objects — that's not promised by Core ML.
        var captured: [Float16] = []
        try captureFloat16(state: src, name: name, into: &captured)
        try writeFloat16Buffer(state: dst, name: name, source: captured)
    }

    private func writeFloat16Buffer(state: MLState, name: String, source: [Float16]) throws {
        var thrown: Error? = nil
        state.withMultiArray(for: name) { buf in
            guard buf.dataType == .float16 else {
                thrown = TTSEngineError.stateBufferDtypeMismatch(name: name, actual: buf.dataType)
                return
            }
            precondition(buf.count == source.count, "state buffer \(name): expected \(source.count) elements, got \(buf.count)")
            let dst = buf.dataPointer.assumingMemoryBound(to: Float16.self)
            source.withUnsafeBufferPointer { sp in
                dst.update(from: sp.baseAddress!, count: source.count)
            }
        }
        if let thrown { throw thrown }
    }

    private func captureFloat16(state: MLState, name: String, into out: inout [Float16]) throws {
        var thrown: Error? = nil
        state.withMultiArray(for: name) { buf in
            guard buf.dataType == .float16 else {
                thrown = TTSEngineError.stateBufferDtypeMismatch(name: name, actual: buf.dataType)
                return
            }
            let src = buf.dataPointer.assumingMemoryBound(to: Float16.self)
            out = Array(UnsafeBufferPointer(start: src, count: buf.count))
        }
        if let thrown { throw thrown }
    }

    // MARK: - Model calls

    private func runPromptPhase(state: MLState, tokens: [Int32], voiceOffset: Int, textLength: Int) throws -> Int {
        let tokensArr = try MLMultiArray(shape: [1, Self.tTextMax as NSNumber], dataType: .int32)
        tokens.withUnsafeBufferPointer { src in
            tokensArr.dataPointer.assumingMemoryBound(to: Int32.self)
                .update(from: src.baseAddress!, count: tokens.count)
        }

        let voiceOffArr = try MLMultiArray(shape: [1], dataType: .int32)
        voiceOffArr.dataPointer.assumingMemoryBound(to: Int32.self).pointee = Int32(voiceOffset)

        let textLenArr = try MLMultiArray(shape: [1], dataType: .int32)
        textLenArr.dataPointer.assumingMemoryBound(to: Int32.self).pointee = Int32(textLength)

        let inputs: [String: MLFeatureValue] = [
            "text_tokens": MLFeatureValue(multiArray: tokensArr),
            "voice_offset": MLFeatureValue(multiArray: voiceOffArr),
            "text_length": MLFeatureValue(multiArray: textLenArr),
        ]
        let out = try promptModel.prediction(
            from: try MLDictionaryFeatureProvider(dictionary: inputs),
            using: state
        )
        guard let tPromptArr = out.featureValue(for: "t_prompt")?.multiArrayValue else {
            throw TTSEngineError.missingOutput("t_prompt")
        }
        return Int(tPromptArr.dataPointer.assumingMemoryBound(to: Int32.self).pointee)
    }

    private func runCaLMStep(state: MLState, prevLatent: [Float], offset: Int32, noise: [Float]) throws -> (latent: [Float], isEos: Bool) {
        let prevArr = try MLMultiArray(shape: [1, 1, Self.ldim as NSNumber], dataType: .float32)
        prevLatent.withUnsafeBufferPointer { src in
            prevArr.dataPointer.assumingMemoryBound(to: Float.self)
                .update(from: src.baseAddress!, count: prevLatent.count)
        }
        let offsetArr = try MLMultiArray(shape: [1], dataType: .int32)
        offsetArr.dataPointer.assumingMemoryBound(to: Int32.self).pointee = offset
        let noiseArr = try MLMultiArray(shape: [1, Self.ldim as NSNumber], dataType: .float32)
        noise.withUnsafeBufferPointer { src in
            noiseArr.dataPointer.assumingMemoryBound(to: Float.self)
                .update(from: src.baseAddress!, count: noise.count)
        }

        let inputs: [String: MLFeatureValue] = [
            "prev_latent": MLFeatureValue(multiArray: prevArr),
            "offset": MLFeatureValue(multiArray: offsetArr),
            "noise": MLFeatureValue(multiArray: noiseArr),
        ]
        let out = try calmModel.prediction(
            from: try MLDictionaryFeatureProvider(dictionary: inputs),
            using: state
        )
        guard let nextLatentArr = out.featureValue(for: "next_latent")?.multiArrayValue,
              let isEosArr = out.featureValue(for: "is_eos")?.multiArrayValue
        else {
            throw TTSEngineError.missingOutput("next_latent / is_eos")
        }

        let nextLatent: [Float] = {
            let p = nextLatentArr.dataPointer.assumingMemoryBound(to: Float.self)
            return Array(UnsafeBufferPointer(start: p, count: nextLatentArr.count))
        }()
        // is_eos is fp32 in the harness's working pipeline (the converter's bool
        // request ends up exposed as float to MLMultiArray). Match the harness.
        let isEosVal = isEosArr.dataPointer.assumingMemoryBound(to: Float.self).pointee
        return (nextLatent, isEosVal > 0.5)
    }

    private func runMimiStep(state: MLState, latent: [Float], offset: Int32) throws -> [Float] {
        let latentArr = try MLMultiArray(shape: [1, 1, Self.ldim as NSNumber], dataType: .float32)
        latent.withUnsafeBufferPointer { src in
            latentArr.dataPointer.assumingMemoryBound(to: Float.self)
                .update(from: src.baseAddress!, count: latent.count)
        }
        let offsetArr = try MLMultiArray(shape: [1], dataType: .int32)
        offsetArr.dataPointer.assumingMemoryBound(to: Int32.self).pointee = offset

        let inputs: [String: MLFeatureValue] = [
            "latent": MLFeatureValue(multiArray: latentArr),
            "offset": MLFeatureValue(multiArray: offsetArr),
        ]
        let out = try mimiModel.prediction(
            from: try MLDictionaryFeatureProvider(dictionary: inputs),
            using: state
        )
        guard let pcmArr = out.featureValue(for: "pcm")?.multiArrayValue else {
            throw TTSEngineError.missingOutput("pcm")
        }
        let p = pcmArr.dataPointer.assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: p, count: pcmArr.count))
    }

    // MARK: - Noise generation

    /// Truncated normal sampler. Matches the reference FlowLM behavior
    /// (`torch.nn.init.trunc_normal_(mean=0, std=std, a=-clamp, b=clamp)`).
    /// Box-Muller for the underlying normal; rejection for the truncation.
    private func sampleTruncNormal(count: Int, std: Float, clamp: Float) -> [Float] {
        var out = [Float](); out.reserveCapacity(count)
        var generator = SystemRandomNumberGenerator()
        while out.count < count {
            // Two independent uniforms in (0, 1] then Box-Muller for two normals
            let u1 = max(.leastNonzeroMagnitude, Float.random(in: 0..<1, using: &generator))
            let u2 = Float.random(in: 0..<1, using: &generator)
            let r = Float(sqrt(-2.0 * Double(log(u1))))
            let theta = 2 * Float.pi * u2
            let z0 = r * cos(theta)
            let z1 = r * sin(theta)
            for z in [z0, z1] {
                let x = z * std
                if x >= -clamp && x <= clamp {
                    out.append(x)
                    if out.count == count { break }
                }
            }
        }
        return out
    }
}
