//
//  TTSEngine.swift
//  pocket-tts-macos
//

import CoreML
import Foundation
import NaturalLanguage

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

// MARK: - Pipeline constants (must match the conversion-project scripts)
// File-scope so nonisolated actor methods can reference them without
// tripping Swift 6's static-property-on-actor isolation rules.
private nonisolated enum K {
    static let nLayers = 6
    static let nHeads = 16
    static let dHead = 64
    static let maxSeq = 512
    static let ldim = 32
    static let tTextMax = 128
    static let mimiOffsetPerFrame: Int32 = 16
    static let mimiPCMPerFrame = 1920
}

// MARK: - TTSEngine
/// Actor-isolated TTS pipeline. One instance per app run; lifecycle-managed by
/// whoever spawns it (in Phase 0c that's the XCTest; later, the SwiftUI shell).
actor TTSEngine: TTSEngineProtocol {

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
        let wallStart = CFAbsoluteTimeGetCurrent()
        print("[PocketTTS] ── synthesis start ──")
        print("[PocketTTS] voice: \(voiceID), text: \(text.count) chars")

        let t0 = CFAbsoluteTimeGetCurrent()
        let voice: LoadedVoice
        if voiceID.hasPrefix("imported:") {
            let importID = String(voiceID.dropFirst("imported:".count))
            voice = try loadImportedVoice(importID: importID)
        } else {
            guard let bundled = voices[voiceID] else {
                throw TTSEngineError.voiceNotFound(voiceID)
            }
            voice = bundled
        }
        let voiceMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        print("[PocketTTS] voice load: \(String(format: "%.1f", voiceMs))ms (T_voice=\(voice.tVoice))")

        let normalized = TextNormalizer.normalize(text)
        let chunks = splitForTokenLimit(normalized)
        print("[PocketTTS] split into \(chunks.count) chunk(s)")
        for (i, chunk) in chunks.enumerated() {
            if chunks.count > 1 { print("[PocketTTS] chunk \(i + 1)/\(chunks.count)") }
            try runSynthesisChunk(text: chunk, voice: voice, options: options, continuation: continuation)
        }

        let wallTotal = CFAbsoluteTimeGetCurrent() - wallStart
        print("[PocketTTS] total wall: \(String(format: "%.2f", wallTotal))s, \(String(format: "%.1f", Double(text.count) / wallTotal)) chars/s")
        print("[PocketTTS] ── synthesis end ──")
    }

    private func runSynthesisChunk(
        text: String,
        voice: LoadedVoice,
        options: SynthesisOptions,
        continuation: AsyncStream<PCMFrame>.Continuation
    ) throws {
        // 1) Tokenize.
        let tTokenize = CFAbsoluteTimeGetCurrent()
        let (tokens, textLen) = try tokenizer.encode(text, paddedLength: K.tTextMax)
        guard textLen <= K.tTextMax else {
            throw TTSEngineError.textOverflow(actualTokens: textLen, max: K.tTextMax)
        }
        let tokenizeMs = (CFAbsoluteTimeGetCurrent() - tTokenize) * 1000
        print("[PocketTTS] tokenize: \(String(format: "%.1f", tokenizeMs))ms (\(textLen) tokens)")

        // 2) Fresh states for each synthesize call (no carry-over from prior runs).
        let promptState = promptModel.makeState()
        let calmState = calmModel.makeState()
        let mimiState = mimiModel.makeState()

        // 3) Seed prompt_phase state with voice K/V (positions 0..tVoice).
        let tKV = CFAbsoluteTimeGetCurrent()
        try writeVoiceKV(into: promptState, voice: voice)
        let kvMs = (CFAbsoluteTimeGetCurrent() - tKV) * 1000

        // 4) Run prompt_phase once.
        let tPromptPhase = CFAbsoluteTimeGetCurrent()
        let tPrompt = try runPromptPhase(state: promptState, tokens: tokens, voiceOffset: voice.tVoice, textLength: textLen)
        let promptMs = (CFAbsoluteTimeGetCurrent() - tPromptPhase) * 1000
        print("[PocketTTS] prompt phase: \(String(format: "%.1f", promptMs))ms (KV write: \(String(format: "%.1f", kvMs))ms, t_prompt=\(tPrompt))")

        // 5) Copy populated KV from promptState into calmState.
        let tCopy = CFAbsoluteTimeGetCurrent()
        try copyKVState(from: promptState, to: calmState)
        let copyMs = (CFAbsoluteTimeGetCurrent() - tCopy) * 1000
        print("[PocketTTS] KV copy: \(String(format: "%.1f", copyMs))ms")

        // 6) AR loop: CaLM → next_latent → Mimi → PCM frame → emit.
        var prevLatent = [Float](repeating: .nan, count: 1 * 1 * K.ldim)   // BOS = NaN
        var eosStep: Int? = nil
        let loopStart = CFAbsoluteTimeGetCurrent()
        var produced = 0

        for step in 0..<options.maxFrames {
            let frameOffset = Int32(tPrompt + step)
            let noise = sampleTruncNormal(count: K.ldim, std: sqrt(options.temperature), clamp: options.noiseClamp)

            let (nextLatent, isEos) = try runCaLMStep(
                state: calmState,
                prevLatent: prevLatent,
                offset: frameOffset,
                noise: noise
            )

            let pcm = try runMimiStep(
                state: mimiState,
                latent: nextLatent,
                offset: Int32(step) * K.mimiOffsetPerFrame
            )

            produced = step + 1
            let final = isEos && eosStep == nil ? false : (eosStep.map { step >= $0 + options.framesAfterEOS } ?? false)
            continuation.yield(PCMFrame(samples: pcm, isFinal: final))

            if isEos && eosStep == nil { eosStep = step }
            if let e = eosStep, step >= e + options.framesAfterEOS { break }
            prevLatent = nextLatent
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - loopStart
        let audioSec = Double(produced * K.mimiPCMPerFrame) / 24_000.0
        let fps = elapsed > 0 ? Double(produced) / elapsed : 0
        let rtf = elapsed > 0 ? audioSec / elapsed : 0
        print("[PocketTTS] AR loop: \(produced) frames, \(String(format: "%.2f", audioSec))s audio in \(String(format: "%.2f", elapsed))s (\(String(format: "%.1f", fps)) fps, \(String(format: "%.1f", rtf))x real-time)")
    }

    // MARK: - Imported voice loading

    private var importedVoiceCache: [String: LoadedVoice] = [:]

    private func loadImportedVoice(importID: String) throws -> LoadedVoice {
        if let cached = importedVoiceCache[importID] { return cached }

        // Read the persisted KV path from the voice catalog JSON on disk.
        // Can't access @MainActor FishVoiceManager from this actor, so we
        // parse the catalog file directly.
        let kvPath = try Self.findImportedVoiceKVPath(importID: importID)

        let voice = try VoiceLoader.loadVoice(from: kvPath)
        importedVoiceCache[importID] = voice
        print("[TTSEngine] loaded imported voice \(importID) (T_voice=\(voice.tVoice))")
        return voice
    }

    private nonisolated static func findImportedVoiceKVPath(importID: String) throws -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let catalogURL = appSupport.appendingPathComponent("pocket-tts-macos/fish-voices/voices.json")

        // Try reading persisted path from catalog
        if let data = try? Data(contentsOf: catalogURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let voices = try? decoder.decode([FishVoice].self, from: data),
               let voice = voices.first(where: { $0.id == importID }),
               let kvPath = voice.pocketTTSKVPath,
               FileManager.default.fileExists(atPath: kvPath) {
                return URL(fileURLWithPath: kvPath)
            }
        }

        // Fallback to conventional path
        let fallback = appSupport.appendingPathComponent("pocket-tts-macos/fish-voices/\(importID)_kv.safetensors")
        guard FileManager.default.fileExists(atPath: fallback.path) else {
            throw TTSEngineError.voiceNotFound("imported:\(importID) — KV not found")
        }
        return fallback
    }

    // MARK: - Text splitting

    /// Split `text` into chunks that each fit within the 128-token limit.
    /// Short text returns as a single-element array (fast path).
    private func splitForTokenLimit(_ text: String) -> [String] {
        if fitsInTokenLimit(text) { return [text] }

        let sentences = Self.splitIntoSentences(text)

        // Greedily pack consecutive sentences into the largest chunks that fit.
        var chunks: [String] = []
        var current = ""
        for sentence in sentences {
            let candidate = current.isEmpty ? sentence : current + " " + sentence
            if fitsInTokenLimit(candidate) {
                current = candidate
            } else {
                if !current.isEmpty { chunks.append(current) }
                current = sentence
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.isEmpty ? [text] : chunks
    }

    private func fitsInTokenLimit(_ text: String) -> Bool {
        (try? tokenizer.encode(text, paddedLength: K.tTextMax)) != nil
    }

    private nonisolated static func splitIntoSentences(_ text: String) -> [String] {
        let tok = NLTokenizer(unit: .sentence)
        tok.string = text
        var result: [String] = []
        tok.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { result.append(s) }
            return true
        }
        return result.isEmpty ? [text] : result
    }

    // MARK: - State seeding

    private func writeVoiceKV(into state: MLState, voice: LoadedVoice) throws {
        for i in 0..<K.nLayers {
            try writeFloat16Buffer(state: state, name: "kv_k_\(i)", source: voice.kCaches[i])
            try writeFloat16Buffer(state: state, name: "kv_v_\(i)", source: voice.vCaches[i])
        }
    }

    private func copyKVState(from src: MLState, to dst: MLState) throws {
        // 12 buffers, each maxSeq * nHeads * dHead = 524288 Float16 elements = 1 MiB.
        // Use one tmp buffer per layer to avoid re-allocations across the loop.
        for i in 0..<K.nLayers {
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
        let tokensArr = try MLMultiArray(shape: [1, K.tTextMax as NSNumber], dataType: .int32)
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
        let prevArr = try MLMultiArray(shape: [1, 1, K.ldim as NSNumber], dataType: .float32)
        prevLatent.withUnsafeBufferPointer { src in
            prevArr.dataPointer.assumingMemoryBound(to: Float.self)
                .update(from: src.baseAddress!, count: prevLatent.count)
        }
        let offsetArr = try MLMultiArray(shape: [1], dataType: .int32)
        offsetArr.dataPointer.assumingMemoryBound(to: Int32.self).pointee = offset
        let noiseArr = try MLMultiArray(shape: [1, K.ldim as NSNumber], dataType: .float32)
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
        let latentArr = try MLMultiArray(shape: [1, 1, K.ldim as NSNumber], dataType: .float32)
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
