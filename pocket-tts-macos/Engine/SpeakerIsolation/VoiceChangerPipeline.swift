//
//  VoiceChangerPipeline.swift
//  pocket-tts-macos
//
//  Orchestrator that turns input audio into a re-voiced WAV with
//  original silences preserved.
//
//  Pipeline:
//
//      input audio  ──► STTProvider ──► [TranscribedSegment]
//                                            │
//                  totalDuration (AVFoundation)
//                                            ▼
//                       SilencePreservingScriptBuilder.build(...)
//                                            │  "[1.2s] Hello [0.4s] world [0.8s]"
//                                            ▼
//                       TTSEngineProtocol.synthesize(text:voiceID:)
//                                            │  AsyncStream<PCMFrame>
//                                            ▼
//                                       collect samples
//                                            ▼
//                                     WAV at outputURL
//
//  The Voice Changer adds no new TTS code paths — the existing
//  TTSEngine already parses `[Xs]` markers (via
//  `TextNormalizer.parsePauseMarkers`) and emits silence frames (via
//  `TTSEngine.yieldSilence`). The port lives entirely in the
//  script-builder + this orchestrator.

@preconcurrency import AVFoundation
import Foundation

actor VoiceChangerPipeline {

    enum PipelineError: Error, CustomStringConvertible {
        case audioMetadataFailed(URL, Error)
        case emptyTranscription
        case outputWriteFailed(URL, Error)

        var description: String {
            switch self {
            case .audioMetadataFailed(let url, let err):
                return "could not read audio metadata for \(url.lastPathComponent): \(err.localizedDescription)"
            case .emptyTranscription:
                return "STT produced no speech segments"
            case .outputWriteFailed(let url, let err):
                return "failed to write \(url.lastPathComponent): \(err.localizedDescription)"
            }
        }
    }

    struct Options: Sendable {
        /// Pause-marker gap floor. Below this, gaps are dropped.
        var minSilenceSec: Double = SilencePreservingScriptBuilder.defaultMinSilenceSec
        /// When true, pad the script with a trailing `[Xs]` so the
        /// output audio length matches the input audio length (within
        /// TTS prosody variability). When false, no trailing pause —
        /// the output ends with the last synthesized segment.
        var includeTrailingSilence: Bool = true
        /// Forwarded to `TTSEngine.synthesize` per chunk.
        var synthesis: SynthesisOptions = SynthesisOptions()
        /// When non-nil, the assembled script is written to this URL
        /// before synthesis — useful for debugging marker placement.
        var debugScriptDumpURL: URL? = nil

        init() {}
    }

    /// TTSEngine emits 24 kHz mono Float32 frames; we write the
    /// collected stream out at the same rate. Centralized constant
    /// here so we don't accidentally ship a 16 kHz "voice changer"
    /// output that the rest of the app's playback / preview path
    /// can't decode.
    private static let outputSampleRate: Int = 24_000

    private let stt: STTProvider
    private let tts: TTSEngineProtocol

    init(stt: STTProvider, tts: TTSEngineProtocol) {
        self.stt = stt
        self.tts = tts
    }

    /// Run the full pipeline. Returns the resulting (script, output URL).
    /// The script is returned for UI display / debugging — callers may
    /// ignore it.
    @discardableResult
    func convert(
        inputAudio: URL,
        voiceID: String,
        outputURL: URL,
        options: Options = Options()
    ) async throws -> (script: String, outputURL: URL) {

        let totalDuration = try await Self.loadDurationSec(inputAudio)

        let segments = try await stt.transcribeSegments(inputAudio)
        guard !segments.isEmpty else { throw PipelineError.emptyTranscription }

        let script = SilencePreservingScriptBuilder.build(
            segments: segments,
            totalDurationSec: options.includeTrailingSilence ? totalDuration : nil,
            minSilenceSec: options.minSilenceSec
        )

        if let dumpURL = options.debugScriptDumpURL {
            try? Data(script.utf8).write(to: dumpURL)
        }

        // TTSEngine emits 80 ms PCM frames @ 24 kHz mono Float32.
        // Accumulate into one buffer; the final frame is allowed to be
        // shorter than 1920 samples.
        var samples: [Float] = []
        samples.reserveCapacity(Int(totalDuration * Double(Self.outputSampleRate) * 1.25))

        let stream = tts.synthesize(text: script, voiceID: voiceID, options: options.synthesis)
        for await frame in stream {
            samples.append(contentsOf: frame.samples)
            if frame.isFinal { break }
        }

        do {
            // Reuse the project's existing WAVEncoder (Audio/
            // WAVEncoder.swift) — single source of truth for WAV
            // writing. The Windows-side port shipped with its own
            // inline WAVWriter as a "no-external-deps" fallback; we
            // delete it in favor of the canonical encoder.
            try WAVEncoder.write(
                samples: samples,
                to: outputURL,
                sampleRate: Self.outputSampleRate
            )
        } catch {
            throw PipelineError.outputWriteFailed(outputURL, error)
        }

        return (script, outputURL)
    }

    // MARK: - Audio metadata

    private static func loadDurationSec(_ url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        do {
            let duration: CMTime
            if #available(macOS 13.0, iOS 16.0, *) {
                duration = try await asset.load(.duration)
            } else {
                duration = asset.duration
            }
            return CMTimeGetSeconds(duration)
        } catch {
            throw PipelineError.audioMetadataFailed(url, error)
        }
    }
}
