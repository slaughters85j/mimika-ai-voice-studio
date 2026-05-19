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
/// Defaults match the Python pocket-tts reference (`default_parameters.py`):
///   DEFAULT_TEMPERATURE = 0.7
///   DEFAULT_NOISE_CLAMP = None  → represented here as Optional<Float>; nil
///                                  means no truncation of the sampled normal.
nonisolated struct SynthesisOptions: Sendable {
    var maxFrames: Int = 256
    var framesAfterEOS: Int = 1
    var temperature: Float = 0.7
    var noiseClamp: Float? = nil

    /// Per-chunk SentencePiece-token budget for the sentence-aware
    /// splitter. Smaller = shorter chunks = less per-chunk AR error
    /// accumulation, at the cost of more chunk-boundary resets.
    /// Python's reference uses 50 (matching the fp32 model's tolerance);
    /// our Core ML build is fp16 and may benefit from a smaller value
    /// on long-sentence inputs. Surfaced as a Settings slider so the
    /// user can tune per script. Range used by the UI: 15–50.
    var chunkTokenBudget: Int = 50

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

    /// Per-chunk SentencePiece-token budget for the sentence-aware
    /// splitter. Matches Python `max_nb_tokens_in_a_chunk = 50` in
    /// `split_into_best_sentences` — empirically tuned to keep
    /// cumulative AR error from compounding at the back end of long
    /// generations. Smaller than the model's 128-token hard limit on
    /// purpose; packing fewer tokens per chunk gives noticeably better
    /// prosody on multi-sentence input.
    static let chunkTokenBudget = 50
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
            // When the consumer's Task is cancelled (or its iterator is
            // dropped), `onTermination` fires. We flip the cancel flag
            // here so the producer's AR loop notices on its next check.
            // Without this, the unstructured `Task { ... }` below keeps
            // running long after the user hit stop.
            let cancel = CancellationFlag()
            continuation.onTermination = { _ in cancel.cancel() }
            Task {
                do {
                    try await self.runSynthesis(text: text, voiceID: voiceID, options: options, continuation: continuation, cancel: cancel)
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
        continuation: AsyncStream<PCMFrame>.Continuation,
        cancel: CancellationFlag
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
        let chunks = splitForTokenLimit(normalized, budget: options.chunkTokenBudget)
        print("[PocketTTS] split into \(chunks.count) chunk(s) (budget \(options.chunkTokenBudget))")
        for (i, chunk) in chunks.enumerated() {
            if cancel.isCancelled {
                print("[PocketTTS] cancelled before chunk \(i + 1)/\(chunks.count)")
                break
            }
            if chunks.count > 1 { print("[PocketTTS] chunk \(i + 1)/\(chunks.count)") }
            try runSynthesisChunk(text: chunk, voice: voice, options: options, continuation: continuation, cancel: cancel)
        }

        let wallTotal = CFAbsoluteTimeGetCurrent() - wallStart
        print("[PocketTTS] total wall: \(String(format: "%.2f", wallTotal))s, \(String(format: "%.1f", Double(text.count) / wallTotal)) chars/s")
        print("[PocketTTS] ── synthesis end ──")
    }

    private func runSynthesisChunk(
        text: String,
        voice: LoadedVoice,
        options: SynthesisOptions,
        continuation: AsyncStream<PCMFrame>.Continuation,
        cancel: CancellationFlag
    ) throws {
        // Per-chunk text prep (P0-3): collapse whitespace, capitalize first,
        // ensure terminal punctuation, pad short prompts. Also yields the
        // per-chunk `framesAfterEosGuess` we add 2 to for trailing tail.
        guard let prepared = TextPreprocessor.prepareTextPrompt(text) else { return }
        var chunkOptions = options
        chunkOptions.framesAfterEOS = prepared.framesAfterEosGuess + 2

        // 1) Tokenize.
        let tTokenize = CFAbsoluteTimeGetCurrent()
        let (tokens, textLen) = try tokenizer.encode(prepared.text, paddedLength: K.tTextMax)
        guard textLen <= K.tTextMax else {
            throw TTSEngineError.textOverflow(actualTokens: textLen, max: K.tTextMax)
        }
        let tokenizeMs = (CFAbsoluteTimeGetCurrent() - tTokenize) * 1000
        print("[PocketTTS] tokenize: \(String(format: "%.1f", tokenizeMs))ms (\(textLen) tokens, framesAfterEOS=\(chunkOptions.framesAfterEOS))")

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

        for step in 0..<chunkOptions.maxFrames {
            if cancel.isCancelled {
                print("[PocketTTS] AR loop cancelled at frame \(step)/\(chunkOptions.maxFrames)")
                break
            }
            let frameOffset = Int32(tPrompt + step)
            let noise = sampleTruncNormal(count: K.ldim, std: sqrt(chunkOptions.temperature), clamp: chunkOptions.noiseClamp)

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
            let final = isEos && eosStep == nil ? false : (eosStep.map { step >= $0 + chunkOptions.framesAfterEOS } ?? false)
            continuation.yield(PCMFrame(samples: pcm, isFinal: final))

            if isEos && eosStep == nil { eosStep = step }
            if let e = eosStep, step >= e + chunkOptions.framesAfterEOS { break }
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

    /// Split `text` into chunks suitable for separate AR generations.
    /// `budget` is the per-chunk SentencePiece-token target (caller-supplied,
    /// driven by the app-level setting). Uses the SentencePiece-aware
    /// chunker for `SentencePieceTokenizer`; falls back to a single chunk
    /// for the test-only `FixedPhraseTokenizer` (its phrase is already
    /// small enough to fit).
    ///
    /// Two-pass design. The sentence-aware chunker packs to `budget` and
    /// can return individual chunks larger than that when a single
    /// sentence exceeds it — including the pathological case of an LLM
    /// emitting a run-on with no internal `.`/`!`/`?`. The second pass
    /// flat-maps any chunk that's still over the model's hard
    /// `K.tTextMax` limit through `subdivideIfNeeded`, which falls back
    /// to comma/semicolon/colon boundaries, then word boundaries, then a
    /// hard token-index cut. Leave a small headroom (`-8`) below
    /// `K.tTextMax` so the per-chunk `TextPreprocessor.prepareTextPrompt`
    /// has room to pad short chunks with 8 leading spaces if it wants to.
    private func splitForTokenLimit(_ text: String, budget: Int) -> [String] {
        guard let sp = tokenizer as? SentencePieceTokenizer else { return [text] }
        let sentenceChunks = sp.splitIntoBestSentences(text, maxTokensPerChunk: budget)
        let withFit = sentenceChunks.flatMap {
            sp.subdivideIfNeeded($0, maxTokens: K.tTextMax - 8)
        }
        return withFit.isEmpty ? [text] : withFit
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
    /// When `clamp` is nil, no truncation is applied (matches Python's
    /// `DEFAULT_NOISE_CLAMP = None`).
    private func sampleTruncNormal(count: Int, std: Float, clamp: Float?) -> [Float] {
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
                if let c = clamp {
                    if x >= -c && x <= c {
                        out.append(x)
                        if out.count == count { break }
                    }
                } else {
                    out.append(x)
                    if out.count == count { break }
                }
            }
        }
        return out
    }
}
