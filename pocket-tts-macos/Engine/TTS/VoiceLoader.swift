//
//  VoiceLoader.swift
//  pocket-tts-macos
//

import Foundation

// MARK: - LoadedVoice
// A voice's precomputed CaLM KV cache plus its valid-position count. Both K
// and V are stored per layer as flat fp16 arrays sized to `maxSeq * nHeads * dHead`.
// Slots beyond `tVoice` are zero (either by construction in the padded-export
// format, or zero-filled here for the v1.5 trimmed format).
//
// Memory: 12 layers × MAX_SEQ * 16 * 64 × Float16 = 12 × 1 MB = 12 MB per voice.
// With 34 voices loaded eagerly that's ~408 MB resident — fine; matches the
// padded on-disk size and avoids any IO during synthesize().

struct LoadedVoice: Sendable {
    let id: String
    let tVoice: Int                  // count of valid positions in [0..maxSeq)
    let kCaches: [[Float16]]         // 6 layers
    let vCaches: [[Float16]]         // 6 layers
}

// MARK: - VoiceLoader
// Pure-Swift safetensors parser specialized for the voice KV files produced by
// `05_export_voice_kv_states.py`. We don't pull in a general-purpose safetensors
// crate because (a) there's no first-party Swift one and (b) the layout we need
// to read is rigid and tiny — 12 named tensors plus one JSON metadata blob.
//
// safetensors layout (https://github.com/huggingface/safetensors):
//   bytes 0..7   : uint64 little-endian header length N
//   bytes 8..N+8 : UTF-8 JSON; keys are tensor names, plus optional "__metadata__"
//   bytes N+8..  : packed tensor data; each tensor lives at the file offset
//                  `N + 8 + data_offsets[0]`, length `data_offsets[1] - data_offsets[0]`

enum VoiceLoaderError: Error, CustomStringConvertible {
    case ioError(URL, Error)
    case headerTooSmall(URL)
    case badJSON(URL)
    case missingMetadata(URL)
    case badMetadata(URL, String)
    case missingTensor(URL, String)
    case unexpectedDtype(URL, String, String)
    case unexpectedShape(URL, String, [Int])

    var description: String {
        switch self {
        case let .ioError(u, e):
            return "I/O error reading \(u.lastPathComponent): \(e)"
        case let .headerTooSmall(u):
            return "\(u.lastPathComponent): header too small (file truncated?)"
        case let .badJSON(u):
            return "\(u.lastPathComponent): cannot decode header JSON"
        case let .missingMetadata(u):
            return "\(u.lastPathComponent): missing __metadata__.info"
        case let .badMetadata(u, why):
            return "\(u.lastPathComponent): bad metadata — \(why)"
        case let .missingTensor(u, name):
            return "\(u.lastPathComponent): missing tensor \(name)"
        case let .unexpectedDtype(u, name, dtype):
            return "\(u.lastPathComponent): tensor \(name) has dtype \(dtype); expected F16"
        case let .unexpectedShape(u, name, shape):
            return "\(u.lastPathComponent): tensor \(name) has shape \(shape); expected [1, *, 16, 64]"
        }
    }
}

nonisolated enum VoiceLoader {

    // MARK: - Constants (must match the conversion-project export script)
    static let nLayers = 6
    static let nHeads = 16
    static let dHead = 64
    static let maxSeq = 512

    /// Slot count per (K or V) buffer when laid out flat.
    static var bufferLength: Int { maxSeq * nHeads * dHead }

    // MARK: - API

    /// Load one voice file from disk. Accepts both the padded shape
    /// `[1, maxSeq, 16, 64]` (current export) and the trimmed shape
    /// `[1, T_voice, 16, 64]` (v1.5 export). In the trimmed case, the
    /// returned buffer is zero-filled beyond `T_voice` so downstream code
    /// always sees a full-length buffer.
    static func loadVoice(from url: URL) throws -> LoadedVoice {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw VoiceLoaderError.ioError(url, error)
        }

        guard data.count >= 8 else { throw VoiceLoaderError.headerTooSmall(url) }
        let headerLen = data[0..<8].withUnsafeBytes { rb in
            rb.load(as: UInt64.self).littleEndian
        }
        guard data.count >= 8 + Int(headerLen) else { throw VoiceLoaderError.headerTooSmall(url) }

        let headerSlice = data[8..<(8 + Int(headerLen))]
        guard
            let json = try? JSONSerialization.jsonObject(with: headerSlice) as? [String: Any]
        else {
            throw VoiceLoaderError.badJSON(url)
        }

        // Metadata: pull T_voice out of the JSON-encoded "info" blob.
        guard
            let meta = json["__metadata__"] as? [String: Any],
            let infoString = meta["info"] as? String,
            let infoData = infoString.data(using: .utf8),
            let info = try? JSONSerialization.jsonObject(with: infoData) as? [String: Any]
        else {
            throw VoiceLoaderError.missingMetadata(url)
        }

        guard let tVoiceAny = info["T_voice"], let tVoice = (tVoiceAny as? NSNumber)?.intValue
        else {
            throw VoiceLoaderError.badMetadata(url, "T_voice missing or not an integer")
        }

        let dataStart = 8 + Int(headerLen)
        var kCaches: [[Float16]] = []
        var vCaches: [[Float16]] = []
        kCaches.reserveCapacity(nLayers)
        vCaches.reserveCapacity(nLayers)

        for i in 0..<nLayers {
            kCaches.append(try readBuffer(name: "kv_k_\(i)", header: json, source: data, dataStart: dataStart, url: url))
            vCaches.append(try readBuffer(name: "kv_v_\(i)", header: json, source: data, dataStart: dataStart, url: url))
        }

        let id = url.deletingPathExtension().lastPathComponent
        return LoadedVoice(id: id, tVoice: tVoice, kCaches: kCaches, vCaches: vCaches)
    }

    /// Load every `<id>.safetensors` discovered in `Resources/voice_kv_states/`.
    /// Returns a `[VoiceID: LoadedVoice]` map ready to be held by the engine
    /// for the lifetime of the app.
    static func loadAll() throws -> [String: LoadedVoice] {
        let urls = try ModelPaths.allVoiceKVStateFiles()
        var out: [String: LoadedVoice] = [:]
        out.reserveCapacity(urls.count)
        for u in urls {
            let v = try loadVoice(from: u)
            out[v.id] = v
        }
        return out
    }

    // MARK: - Helpers

    /// Read one fp16 tensor named `name` and return a flat `[Float16]` of length
    /// `bufferLength` (= maxSeq * nHeads * dHead), zero-filling beyond `tVoice` if
    /// the on-disk tensor was stored in the trimmed shape.
    private static func readBuffer(
        name: String,
        header: [String: Any],
        source: Data,
        dataStart: Int,
        url: URL
    ) throws -> [Float16] {
        guard let entry = header[name] as? [String: Any] else {
            throw VoiceLoaderError.missingTensor(url, name)
        }
        guard let dtype = entry["dtype"] as? String, dtype == "F16" else {
            throw VoiceLoaderError.unexpectedDtype(url, name, entry["dtype"] as? String ?? "?")
        }
        guard
            let shapeAny = entry["shape"] as? [Any],
            shapeAny.count == 4,
            let s0 = (shapeAny[0] as? NSNumber)?.intValue,
            let s1 = (shapeAny[1] as? NSNumber)?.intValue,
            let s2 = (shapeAny[2] as? NSNumber)?.intValue,
            let s3 = (shapeAny[3] as? NSNumber)?.intValue,
            s0 == 1, s2 == nHeads, s3 == dHead, s1 >= 1, s1 <= maxSeq
        else {
            throw VoiceLoaderError.unexpectedShape(url, name, (entry["shape"] as? [Any]).map { $0.compactMap { ($0 as? NSNumber)?.intValue } } ?? [])
        }
        guard
            let offsets = entry["data_offsets"] as? [Any],
            offsets.count == 2,
            let lo = (offsets[0] as? NSNumber)?.intValue,
            let hi = (offsets[1] as? NSNumber)?.intValue,
            hi >= lo
        else {
            throw VoiceLoaderError.badMetadata(url, "tensor \(name) has malformed data_offsets")
        }

        let onDiskCount = s0 * s1 * s2 * s3
        let byteCount = hi - lo
        guard byteCount == onDiskCount * MemoryLayout<Float16>.size else {
            throw VoiceLoaderError.badMetadata(url, "tensor \(name) byte range \(byteCount) doesn't match shape product \(onDiskCount) × 2")
        }

        // Read on-disk bytes into a Float16 array of size onDiskCount.
        var onDisk = [Float16](repeating: 0, count: onDiskCount)
        let absStart = dataStart + lo
        source.withUnsafeBytes { src in
            let srcBase = src.baseAddress!.advanced(by: absStart)
            _ = onDisk.withUnsafeMutableBufferPointer { dst in
                memcpy(dst.baseAddress, srcBase, byteCount)
            }
        }

        // Expand to bufferLength if this voice was exported with the trimmed shape.
        if s1 == maxSeq {
            return onDisk
        }
        // Trimmed: place valid slots at front of full-length buffer, zero-pad the rest.
        var full = [Float16](repeating: 0, count: bufferLength)
        let validSlots = s1 * nHeads * dHead
        full.replaceSubrange(0..<validSlots, with: onDisk)
        return full
    }
}
