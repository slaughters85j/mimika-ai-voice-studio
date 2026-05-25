//
//  NpyReader.swift
//  pocket-tts-macosTests
//
//  Minimal NumPy `.npy` file reader for the LavaSR parity test
//  fixtures. Supports 1D Float32 little-endian arrays — the only flavor
//  produced by `scripts/validate_lavasr_enhancement.py`.
//
//  The full .npy spec is at
//      https://numpy.org/doc/stable/reference/generated/numpy.lib.format.html
//  We implement only the subset we need (v1.0 header, single dtype).

import Foundation
import XCTest

// MARK: - NpyReader

enum NpyReader {

    enum Error: Swift.Error, CustomStringConvertible {
        case fileNotFound(URL)
        case readFailed(URL)
        case invalidMagic([UInt8])
        case unsupportedVersion(major: UInt8, minor: UInt8)
        case headerParseFailed(String)
        case unsupportedDtype(String)
        case lengthMismatch(expected: Int, actual: Int)

        var description: String {
            switch self {
            case .fileNotFound(let url):
                return "NpyReader: file not found at \(url.path)"
            case .readFailed(let url):
                return "NpyReader: failed to read \(url.path)"
            case .invalidMagic(let bytes):
                return "NpyReader: not a .npy file (magic=\(bytes))"
            case .unsupportedVersion(let major, let minor):
                return "NpyReader: unsupported .npy version \(major).\(minor)"
            case .headerParseFailed(let msg):
                return "NpyReader: header parse failed: \(msg)"
            case .unsupportedDtype(let descr):
                return "NpyReader: unsupported dtype \(descr) (only '<f4' is handled)"
            case .lengthMismatch(let expected, let actual):
                return "NpyReader: declared length \(expected) but only \(actual) Float32s in body"
            }
        }
    }

    /// Load a 1D Float32 array from a `.npy` file written by
    /// `numpy.save(...)`. Throws on malformed files or unsupported
    /// dtypes; returns the `[Float]` payload otherwise.
    static func loadFloat32Array(at url: URL) throws -> [Float] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Error.fileNotFound(url)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw Error.readFailed(url)
        }

        // Header — minimum bytes for a v1.0 file: 6 (magic) + 2 (ver) + 2 (header_len)
        guard data.count >= 10 else {
            throw Error.headerParseFailed("file too small to contain a header")
        }
        let magic: [UInt8] = Array(data[0..<6])
        let expected: [UInt8] = [0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59]  // "\x93NUMPY"
        guard magic == expected else { throw Error.invalidMagic(magic) }

        let major = data[6]
        let minor = data[7]
        guard major == 1, minor == 0 else {
            throw Error.unsupportedVersion(major: major, minor: minor)
        }

        let headerLen = Int(data[8]) | (Int(data[9]) << 8)
        let headerStart = 10
        let headerEnd = headerStart + headerLen
        guard data.count >= headerEnd else {
            throw Error.headerParseFailed("declared header length \(headerLen) exceeds file size")
        }
        let headerBytes = data[headerStart..<headerEnd]
        guard let header = String(data: headerBytes, encoding: .ascii) else {
            throw Error.headerParseFailed("header is not ASCII")
        }

        // Validate dtype is '<f4' (little-endian float32).
        if !header.contains("'descr': '<f4'") && !header.contains("\"descr\": \"<f4\"") {
            // Pull the descr value out so the error message is useful.
            let descr: String
            if let range = header.range(of: "'descr': '"),
               let end = header[range.upperBound...].firstIndex(of: "'") {
                descr = String(header[range.upperBound..<end])
            } else {
                descr = "<unparseable descr>"
            }
            throw Error.unsupportedDtype(descr)
        }

        let shape = try _parseShape(header)
        let totalSamples = shape.reduce(1, *)
        let bodyOffset = headerEnd
        let bodyByteCount = data.count - bodyOffset
        let actualSamples = bodyByteCount / MemoryLayout<Float>.size
        guard actualSamples >= totalSamples else {
            throw Error.lengthMismatch(expected: totalSamples, actual: actualSamples)
        }

        // Copy body bytes into [Float]. The bytes are little-endian
        // float32 — matches Apple Silicon native representation, so a
        // direct memcpy works.
        var out = [Float](repeating: 0, count: totalSamples)
        out.withUnsafeMutableBytes { dst in
            let src = data.subdata(in: bodyOffset..<bodyOffset + totalSamples * MemoryLayout<Float>.size)
            src.withUnsafeBytes { srcBytes in
                dst.copyMemory(from: srcBytes)
            }
        }
        return out
    }

    /// Load an N-D Float32 .npy and return both the flat row-major
    /// payload and the parsed shape. Useful for module-level parity
    /// tests where the saved tensor is (B, C, T, F).
    static func loadFloat32Tensor(at url: URL) throws -> (samples: [Float], shape: [Int]) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Error.fileNotFound(url)
        }
        // The flat loader already does header parsing — we re-do the
        // shape parse here so the caller gets the dims. Cheap.
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw Error.readFailed(url)
        }
        guard data.count >= 10 else {
            throw Error.headerParseFailed("file too small")
        }
        let headerLen = Int(data[8]) | (Int(data[9]) << 8)
        let headerEnd = 10 + headerLen
        guard data.count >= headerEnd else {
            throw Error.headerParseFailed("header overruns file")
        }
        guard let header = String(data: data[10..<headerEnd], encoding: .ascii) else {
            throw Error.headerParseFailed("non-ascii header")
        }
        let shape = try _parseShape(header)
        let samples = try loadFloat32Array(at: url)  // Flat payload
        return (samples, shape)
    }

    /// Parse the `'shape': (D0, D1, ...)` tuple out of the .npy header.
    /// Accepts arbitrary rank, including `(N,)` for 1D.
    private static func _parseShape(_ header: String) throws -> [Int] {
        guard let shapeMarker = header.range(of: "'shape': (") else {
            throw Error.headerParseFailed("missing 'shape' field")
        }
        let afterMarker = header[shapeMarker.upperBound...]
        guard let closeIdx = afterMarker.firstIndex(of: ")") else {
            throw Error.headerParseFailed("malformed shape tuple")
        }
        let shapeStr = String(afterMarker[..<closeIdx])
        let dims = shapeStr.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { Int($0) }
        guard !dims.isEmpty else {
            throw Error.headerParseFailed("shape tuple was empty")
        }
        return dims
    }

    // MARK: - Convenience

    /// Compile-time path to this very file (resolved once, baked in).
    /// Used to anchor the fixtures-dir lookup so it doesn't depend on
    /// which test file calls phase10FixturesDir().
    ///
    /// CAVEAT: a `#filePath` *default argument* gets re-resolved at
    /// every call site, so a caller from `LavaSRDenoiserModuleTests.swift`
    /// would yield the wrong base directory. Capturing it here as a
    /// stored constant locks it to `Helpers/NpyReader.swift` regardless
    /// of caller.
    private static let _selfFilePath: String = #filePath

    /// Locate the Phase 10 LavaSR fixtures directory at
    /// `pocket-tts-macosTests/Fixtures/lavasr_phase10/`. The
    /// `#filePath` of THIS file is in `Helpers/`, so we delete the
    /// `Helpers` last-component to get to `pocket-tts-macosTests/`,
    /// then descend into the fixtures subdir.
    static func phase10FixturesDir() -> URL {
        let here = URL(fileURLWithPath: _selfFilePath).deletingLastPathComponent()
        // here is .../pocket-tts-macosTests/Helpers/
        return here
            .deletingLastPathComponent()  // → .../pocket-tts-macosTests/
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("lavasr_phase10", isDirectory: true)
    }

    /// Convenience: load the named .npy from the lavasr_phase10
    /// directory, soft-skip the calling test if absent.
    static func requirePhase10Array(_ name: String) throws -> [Float] {
        let url = phase10FixturesDir().appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip(
                "LavaSR Phase 10 reference '\(name)' not found at \(url.path). " +
                "Run scripts/generate_lavasr_phase10_fixtures.py + " +
                "scripts/validate_lavasr_enhancement.py --full from the lavasr-venv " +
                "to enable this test."
            )
        }
        return try loadFloat32Array(at: url)
    }

    /// N-D variant of `requirePhase10Array`. Returns the flat row-major
    /// payload plus the parsed shape; the test reshapes the payload
    /// into an MLXArray of the matching dimensions.
    static func requirePhase10Tensor(_ name: String) throws -> (samples: [Float], shape: [Int]) {
        let url = phase10FixturesDir().appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip(
                "LavaSR Phase 10 reference '\(name)' not found at \(url.path). " +
                "Run scripts/generate_lavasr_phase10_fixtures.py + " +
                "scripts/validate_lavasr_enhancement.py --full --per-stage from the " +
                "lavasr-venv to enable this test."
            )
        }
        return try loadFloat32Tensor(at: url)
    }

    // MARK: - Metrics

    /// Pearson correlation of two same-length arrays. Returns NaN if
    /// either input has zero variance.
    static func pearsonR(_ a: [Float], _ b: [Float]) -> Double {
        precondition(a.count == b.count, "pearsonR: length mismatch \(a.count) vs \(b.count)")
        let n = Double(a.count)
        var sumA = 0.0, sumB = 0.0, sumAB = 0.0, sumA2 = 0.0, sumB2 = 0.0
        for i in 0..<a.count {
            let ai = Double(a[i])
            let bi = Double(b[i])
            sumA += ai
            sumB += bi
            sumAB += ai * bi
            sumA2 += ai * ai
            sumB2 += bi * bi
        }
        let meanA = sumA / n
        let meanB = sumB / n
        let cov = sumAB / n - meanA * meanB
        let varA = sumA2 / n - meanA * meanA
        let varB = sumB2 / n - meanB * meanB
        let denom = (varA * varB).squareRoot()
        return denom > 0 ? cov / denom : .nan
    }
}
