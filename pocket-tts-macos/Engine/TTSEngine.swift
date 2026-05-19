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
    /// Output sample rate of the Mimi decoder. Used to size pause
    /// silence segments by seconds → samples.
    static let sampleRate = 24_000
    /// 80 ms linear fade window applied at pause boundaries. Matches
    /// Python's `int(0.08 * self.sample_rate)` at `tts_model.py:497`.
    /// At 24 kHz that's exactly one Mimi PCM frame — convenient.
    static let fadeSamples = Int(0.08 * Double(sampleRate))

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

        // P0-4: parse `[Xs]` pause markers FIRST, before normalization.
        // Mirrors Python's `parse_pause_markers(text_to_generate)` call
        // at the top of `generate_audio_stream`. Single-Voice users can
        // now drop `[1.5s]` etc. in their input and we'll emit silence
        // + apply 80 ms boundary fades to the audio around it.
        let segments = TextNormalizer.parsePauseMarkers(text)
        if segments.count > 1 {
            print("[PocketTTS] parsed \(segments.count) segments (\(segments.filter(\.isPause).count) pauses)")
        }

        // Identify the index of the absolute final TEXT segment so the
        // AR-loop final-frame contract (Bug 1's fix) still fires
        // correctly: `isFinal=true` lands on the last frame of the last
        // chunk of the last text segment, regardless of trailing
        // pause / silence frames.
        let lastTextSegmentIndex = segments.lastIndex(where: {
            if case .text = $0 { return true } else { return false }
        }) ?? -1

        for (segIdx, segment) in segments.enumerated() {
            if cancel.isCancelled {
                print("[PocketTTS] cancelled before segment \(segIdx + 1)/\(segments.count)")
                break
            }
            switch segment {
            case let .text(body):
                let prevIsPause = segIdx > 0 && segments[segIdx - 1].isPause
                let nextIsPause = segIdx + 1 < segments.count && segments[segIdx + 1].isPause
                let isLastTextSegment = segIdx == lastTextSegmentIndex
                try runTextSegment(
                    text: body,
                    voice: voice,
                    options: options,
                    continuation: continuation,
                    cancel: cancel,
                    isLastTextSegment: isLastTextSegment,
                    prevIsPause: prevIsPause,
                    nextIsPause: nextIsPause
                )
            case let .pause(seconds):
                yieldSilence(seconds: seconds, continuation: continuation, cancel: cancel)
            }
        }

        let wallTotal = CFAbsoluteTimeGetCurrent() - wallStart
        print("[PocketTTS] total wall: \(String(format: "%.2f", wallTotal))s, \(String(format: "%.1f", Double(text.count) / wallTotal)) chars/s")
        print("[PocketTTS] ── synthesis end ──")
    }

    // MARK: - Per-text-segment dispatch

    /// Drives the existing chunker + AR loop for ONE text segment
    /// (one element from `parsePauseMarkers`'s output that's a
    /// `.text(...)` case). Adds a 1-frame buffer wrapped around the
    /// AR yields so we can apply an 80 ms linear fade-out to the LAST
    /// PCM frame of the segment when a pause follows. Fade-in to the
    /// first frame is applied inline when a pause preceded.
    ///
    /// Latency cost: the buffer delays every yield by one frame
    /// (80 ms). The user perceives a slightly later start to playback
    /// but it's well below the human-perception threshold and Python's
    /// reference implementation has the same delay by design.
    private func runTextSegment(
        text: String,
        voice: LoadedVoice,
        options: SynthesisOptions,
        continuation: AsyncStream<PCMFrame>.Continuation,
        cancel: CancellationFlag,
        isLastTextSegment: Bool,
        prevIsPause: Bool,
        nextIsPause: Bool
    ) throws {
        let normalized = TextNormalizer.normalize(text)
        let chunks = splitForTokenLimit(normalized, budget: options.chunkTokenBudget)
        print("[PocketTTS] split into \(chunks.count) chunk(s) (budget \(options.chunkTokenBudget))")

        // One-frame buffer. `pending` holds the most recently produced
        // PCM frame; we yield it on the NEXT frame's arrival, which
        // means by the time the chunk loop exits, exactly one frame is
        // still buffered. That's where the optional fade-out goes.
        var pending: PCMFrame? = nil
        var isFirstFrameOfSegment = true

        let chunkYield: (PCMFrame) -> Void = { incoming in
            // Apply fade-in to the absolute first audio frame of this
            // text segment when a pause immediately preceded.
            var prepared = incoming
            if isFirstFrameOfSegment && prevIsPause {
                prepared = PCMFrame(
                    samples: Self.applyLinearFadeIn(prepared.samples, fadeSamples: K.fadeSamples),
                    isFinal: prepared.isFinal
                )
            }
            isFirstFrameOfSegment = false

            if let prev = pending {
                continuation.yield(prev)
            }
            pending = prepared
        }

        for (i, chunk) in chunks.enumerated() {
            if cancel.isCancelled {
                print("[PocketTTS] cancelled before chunk \(i + 1)/\(chunks.count)")
                break
            }
            if chunks.count > 1 { print("[PocketTTS] chunk \(i + 1)/\(chunks.count)") }
            // The absolute-last-frame `isFinal=true` contract: only set
            // when this is the last chunk of the last text segment.
            // Pause-segment silence frames never trigger isFinal.
            let isLastChunk = isLastTextSegment && (i == chunks.count - 1)
            try runSynthesisChunk(
                text: chunk,
                voice: voice,
                options: options,
                yield: chunkYield,
                cancel: cancel,
                isLastChunk: isLastChunk
            )
        }

        // Flush the buffered final frame with optional fade-out when a
        // pause follows. Mirrors `tts_model.py:556-562`.
        if let final = pending {
            let out: PCMFrame
            if nextIsPause {
                out = PCMFrame(
                    samples: Self.applyLinearFadeOut(final.samples, fadeSamples: K.fadeSamples),
                    isFinal: final.isFinal
                )
            } else {
                out = final
            }
            continuation.yield(out)
        }
    }

    /// Emits zero-filled PCM frames totalling at least `seconds` of
    /// silence, in 1920-sample chunks (one PCMFrame each). Polls the
    /// cancellation flag between frames so a long pause doesn't block
    /// the stop button. Always uses `isFinal: false` — even if the
    /// pause is the very last segment, the audio that preceded it
    /// already raised isFinal on its actual final frame.
    private nonisolated func yieldSilence(
        seconds: Double,
        continuation: AsyncStream<PCMFrame>.Continuation,
        cancel: CancellationFlag
    ) {
        let totalSamples = max(0, Int((seconds * Double(K.sampleRate)).rounded()))
        if totalSamples == 0 { return }
        let frameSize = K.mimiPCMPerFrame
        let zeros = [Float](repeating: 0, count: frameSize)
        var emitted = 0
        while emitted < totalSamples {
            if cancel.isCancelled {
                print("[PocketTTS] silence cancelled at \(emitted)/\(totalSamples) samples")
                return
            }
            let remaining = totalSamples - emitted
            if remaining >= frameSize {
                continuation.yield(PCMFrame(samples: zeros, isFinal: false))
                emitted += frameSize
            } else {
                // Tail partial frame.
                continuation.yield(PCMFrame(samples: [Float](repeating: 0, count: remaining), isFinal: false))
                emitted += remaining
            }
        }
    }

    // MARK: - Boundary fade helpers (P0-4 / P0-5)
    //
    // Linear ramp over the first / last `fadeSamples` samples of a
    // buffer. Port of the Python idiom:
    //   buffered_chunk[:n] *= torch.linspace(0.0, 1.0, n)  // fade-in
    //   buffered_chunk[-n:] *= torch.linspace(1.0, 0.0, n) // fade-out
    // The Python `linspace(a, b, n)` is INCLUSIVE on both ends — same
    // here. With n == count (typical when fade covers a whole 1920-
    // sample frame), the very first sample is multiplied by 0 and the
    // very last by 1 on fade-in (and reversed on fade-out).

    private nonisolated static func applyLinearFadeIn(_ samples: [Float], fadeSamples: Int) -> [Float] {
        let n = min(fadeSamples, samples.count)
        if n <= 0 { return samples }
        var out = samples
        if n == 1 {
            out[0] = 0
            return out
        }
        let denom = Float(n - 1)
        for i in 0..<n {
            out[i] *= Float(i) / denom
        }
        return out
    }

    private nonisolated static func applyLinearFadeOut(_ samples: [Float], fadeSamples: Int) -> [Float] {
        let n = min(fadeSamples, samples.count)
        if n <= 0 { return samples }
        var out = samples
        if n == 1 {
            out[out.count - 1] = 0
            return out
        }
        let denom = Float(n - 1)
        let start = out.count - n
        for i in 0..<n {
            // Ramp from 1.0 (at i = 0 of the ramp) down to 0.0 (at i = n - 1).
            out[start + i] *= Float(n - 1 - i) / denom
        }
        return out
    }

    /// Synthesize one text chunk through the prompt-phase + AR loop.
    /// Yields PCM frames via the caller-supplied `yield` closure rather
    /// than directly to the AsyncStream continuation — `runTextSegment`
    /// wraps `yield` with a 1-frame buffer so it can apply boundary
    /// fades to the segment's first / last frame.
    private func runSynthesisChunk(
        text: String,
        voice: LoadedVoice,
        options: SynthesisOptions,
        yield: (PCMFrame) -> Void,
        cancel: CancellationFlag,
        isLastChunk: Bool
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
            // `isFinal` is a stream-wide signal — only the absolute last
            // frame of the whole synthesize call gets it. Per-chunk EOS
            // tails are NOT final; the stream continues with the next
            // chunk's prompt + AR loop. `StreamingPlayer` uses isFinal
            // to schedule its drain callback (once per `play(stream:)`),
            // so emitting it per-chunk would fire that callback multiple
            // times — and SingleVoiceViewModel breaks its for-await on
            // isFinal=true. Both wrong before the gate. See plan file.
            let isAtFinalChunkFrame = eosStep.map { step >= $0 + chunkOptions.framesAfterEOS } ?? false
            let final = isLastChunk && isAtFinalChunkFrame
            yield(PCMFrame(samples: pcm, isFinal: final))

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
