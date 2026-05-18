//
//  PocketTTSVoiceEncoder.swift
//  pocket-tts-macos
//
//  Encodes a WAV file into Pocket-TTS KV cache states (safetensors).
//  Uses two Core ML models:
//    1. mimi_encoder.mlpackage: audio → conditioning embeddings
//    2. voice_prompt_phase.mlpackage: conditioning → KV cache (stateful)
//
//  The output safetensors matches the format of the bundled voice files
//  in Resources/voice_kv_states/ and can be loaded by VoiceLoader.

@preconcurrency import AVFoundation
import CoreML
import Foundation

// MARK: - PocketTTSVoiceEncoder

actor PocketTTSVoiceEncoder {

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

    // Constants matching the conversion scripts
    private static let sampleRate = 24_000
    private static let maxSeconds = 15
    private static let fixedSamples = sampleRate * maxSeconds
    private static let tVoiceMax = 200
    private static let nLayers = 6
    private static let nHeads = 16
    private static let dHead = 64
    private static let maxSeq = 512

    private var encoderModel: MLModel?
    private var voicePhaseModel: MLModel?

    // MARK: - Bootstrap

    func bootstrap() throws {
        let cuNoANE = MLModelConfiguration()
        cuNoANE.computeUnits = .cpuAndGPU

        let encoderURL = try ModelPaths.url(forResource: "mimi_encoder", withExtension: "mlmodelc")
        let phaseURL = try ModelPaths.url(forResource: "voice_prompt_phase", withExtension: "mlmodelc")

        self.encoderModel = try MLModel(contentsOf: encoderURL, configuration: cuNoANE)
        self.voicePhaseModel = try MLModel(contentsOf: phaseURL, configuration: cuNoANE)
        print("[PocketTTSVoiceEncoder] models loaded")
    }

    // MARK: - Encode voice from WAV → safetensors

    func encodeVoice(wavURL: URL, outputURL: URL) throws {
        guard let encoder = encoderModel, let phase = voicePhaseModel else {
            throw EncoderError.modelNotFound("Call bootstrap() first")
        }

        // Step 1: Load + resample audio to 24kHz mono
        let samples = try loadAudio(url: wavURL)
        print("[PocketTTSVoiceEncoder] loaded \(samples.count) samples")

        // Step 2: Pad/trim to fixed size
        var padded = [Float](repeating: 0, count: Self.fixedSamples)
        let copyCount = min(samples.count, Self.fixedSamples)
        padded.replaceSubrange(0..<copyCount, with: samples[0..<copyCount])
        let voiceLength = min(copyCount / (Self.sampleRate / 12), Self.tVoiceMax)

        // Step 3: Run mimi_encoder
        let audioArr = try MLMultiArray(shape: [1, 1, Self.fixedSamples as NSNumber], dataType: .float32)
        padded.withUnsafeBufferPointer { src in
            audioArr.dataPointer.assumingMemoryBound(to: Float.self)
                .update(from: src.baseAddress!, count: Self.fixedSamples)
        }

        let encoderInput = try MLDictionaryFeatureProvider(dictionary: ["audio": audioArr])
        let encoderOutput = try encoder.prediction(from: encoderInput)
        guard let conditioning = encoderOutput.featureValue(for: "conditioning")?.multiArrayValue else {
            throw EncoderError.encodeFailed("mimi_encoder returned no conditioning")
        }
        let tFrames = conditioning.shape[1].intValue
        print("[PocketTTSVoiceEncoder] mimi_encoder → \(tFrames) frames")

        // Step 4: Pad conditioning to T_VOICE_MAX
        let condArr = try MLMultiArray(shape: [1, Self.tVoiceMax as NSNumber, 1024], dataType: .float32)
        let condSrc = conditioning.dataPointer.assumingMemoryBound(to: Float.self)
        let condDst = condArr.dataPointer.assumingMemoryBound(to: Float.self)
        let framesToCopy = min(tFrames, Self.tVoiceMax)
        memcpy(condDst, condSrc, framesToCopy * 1024 * MemoryLayout<Float>.size)

        // Step 5: Run voice_prompt_phase (populates KV state)
        let lengthArr = try MLMultiArray(shape: [1], dataType: .int32)
        lengthArr.dataPointer.assumingMemoryBound(to: Int32.self).pointee = Int32(framesToCopy)

        let phaseState = phase.makeState()
        let phaseInput = try MLDictionaryFeatureProvider(dictionary: [
            "conditioning": condArr,
            "voice_length": lengthArr,
        ])
        let _ = try phase.prediction(from: phaseInput, using: phaseState)

        // Step 6: Extract KV cache from state → save as safetensors
        try saveKVState(state: phaseState, tVoice: framesToCopy, outputURL: outputURL)
        print("[PocketTTSVoiceEncoder] saved KV state to \(outputURL.lastPathComponent)")
    }

    // MARK: - Helpers

    private func loadAudio(url: URL) throws -> [Float] {
        let audioFile = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(Self.sampleRate),
            channels: 1,
            interleaved: false
        )!
        let maxFrames = AVAudioFrameCount(Self.maxSeconds * Self.sampleRate)
        let readFrames = min(AVAudioFrameCount(audioFile.length), maxFrames)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: readFrames) else {
            throw EncoderError.encodeFailed("Cannot create audio buffer")
        }

        if Int(audioFile.processingFormat.sampleRate) == Self.sampleRate
            && audioFile.processingFormat.channelCount == 1 {
            try audioFile.read(into: buffer, frameCount: readFrames)
        } else {
            let srcBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: readFrames)!
            try audioFile.read(into: srcBuffer, frameCount: readFrames)
            let converter = AVAudioConverter(from: audioFile.processingFormat, to: format)!
            _ = converter.convert(to: buffer, error: nil) { _, outStatus in
                outStatus.pointee = .haveData
                return srcBuffer
            }
        }

        guard let data = buffer.floatChannelData?[0] else {
            throw EncoderError.encodeFailed("No audio data")
        }
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }

    private func saveKVState(state: MLState, tVoice: Int, outputURL: URL) throws {
        // Extract fp16 KV buffers from state and write as safetensors-compatible format.
        // For now, write as individual .npy files in a directory, then combine.
        // TODO: Write proper safetensors with metadata matching VoiceLoader expectations.

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

        // Write safetensors format matching VoiceLoader expectations
        try writeSafetensors(kvData: kvData, tVoice: tVoice, to: outputURL)
    }

    private func writeSafetensors(kvData: [String: [Float16]], tVoice: Int, to url: URL) throws {
        // Safetensors format:
        //   8 bytes: uint64 LE header length
        //   header: JSON dict with tensor metadata + __metadata__
        //   data: packed tensor bytes

        let shape = [1, Self.maxSeq, Self.nHeads, Self.dHead]
        let bytesPerTensor = shape.reduce(1, *) * MemoryLayout<Float16>.size
        let sortedKeys = kvData.keys.sorted()

        // Build header JSON
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

        // Write file
        var fileData = Data()
        // 8-byte header length (little-endian uint64)
        var headerLen = UInt64(headerData.count)
        fileData.append(Data(bytes: &headerLen, count: 8))
        // Header JSON
        fileData.append(headerData)
        // Tensor data
        for key in sortedKeys {
            guard let buf = kvData[key] else { continue }
            buf.withUnsafeBufferPointer { ptr in
                fileData.append(UnsafeBufferPointer(start: ptr.baseAddress, count: buf.count))
            }
        }

        try fileData.write(to: url, options: .atomic)
    }
}

// MARK: - ModelPaths extension

extension ModelPaths {
    static func url(forResource name: String, withExtension ext: String) throws -> URL {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
            throw PocketTTSVoiceEncoder.EncoderError.modelNotFound("\(name).\(ext)")
        }
        return url
    }
}
