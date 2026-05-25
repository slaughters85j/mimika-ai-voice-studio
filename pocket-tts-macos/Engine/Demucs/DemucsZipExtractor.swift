//
//  DemucsZipExtractor.swift
//  pocket-tts-macos
//
//  Minimal in-process zip extractor used by `DemucsModelInstaller`
//  to unpack the published `htdemucs.mlpackage.zip`. Replaces the
//  earlier `/usr/bin/unzip` subprocess (the project keeps Process()
//  spawning off-limits to stay sandbox + notarization-friendly).
//
//  Scope:
//    * STORE (compressionMethod=0) and DEFLATE (=8) only — what the
//      published mlpackage zip uses. Other methods (BZIP2, LZMA,
//      etc.) throw `.unsupportedCompression` rather than silently
//      mis-extracting.
//    * Zip32 only. Zip64 support isn't needed; the mlpackage is
//      ~287 MB with individual files under 4 GB.
//    * Refuses ".." segments and absolute paths in entry names
//      (zip-slip protection).
//    * Mmap-reads the zip via `Data(contentsOf:options:.mappedIfSafe)`
//      so the working set stays close to the OS file cache.
//
//  Format references (this file follows the field offsets verbatim):
//    * Local File Header:    PK 0x04034b50, 30 bytes + filename + extra
//    * Central Directory:    PK 0x02014b50, 46 bytes + filename + extra + comment
//    * End of Central Dir:   PK 0x06054b50, 22 bytes + comment

import Compression
import Foundation

// MARK: - DemucsZipExtractor

nonisolated enum DemucsZipExtractor {

    // MARK: - Errors

    enum ExtractorError: Error, CustomStringConvertible {
        case invalidFormat(String)
        case unsupportedCompression(UInt16)
        case decompressionFailed(String)
        case unsafeEntryPath(String)
        case writeFailed(URL, Error)

        var description: String {
            switch self {
            case .invalidFormat(let detail):
                return "Invalid zip format: \(detail)"
            case .unsupportedCompression(let m):
                return "Unsupported compression method \(m); only STORE (0) and DEFLATE (8) are supported"
            case .decompressionFailed(let detail):
                return "Decompression failed: \(detail)"
            case .unsafeEntryPath(let name):
                return "Refusing unsafe entry path: \(name)"
            case .writeFailed(let url, let e):
                return "Couldn't write extracted file at \(url.lastPathComponent): \(e.localizedDescription)"
            }
        }
    }

    // MARK: - Public surface

    /// Extract every entry of the zip at `src` into the directory
    /// `dst`. `dst` is created if it doesn't exist. Throws on the
    /// first invalid entry — partial extraction is the caller's
    /// problem to clean up (see `DemucsModelInstaller.install`'s
    /// staging-dir defer).
    static func extract(_ src: URL, into dst: URL) throws {
        let data = try Data(contentsOf: src, options: .mappedIfSafe)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)

        let eocdOffset = try findEOCD(in: data)
        let centralDirOffset = Int(readUInt32LE(data, at: eocdOffset + 16))
        let totalEntries = Int(readUInt16LE(data, at: eocdOffset + 10))

        var offset = centralDirOffset
        var extracted = 0
        while extracted < totalEntries {
            guard offset + 46 <= data.count else {
                throw ExtractorError.invalidFormat(
                    "central directory truncated at entry \(extracted)/\(totalEntries)"
                )
            }
            let sig = readUInt32LE(data, at: offset)
            guard sig == 0x02014b50 else {
                throw ExtractorError.invalidFormat(
                    "expected CD entry signature, got 0x\(String(sig, radix: 16))"
                )
            }

            let entry = try parseCDEntry(data, at: offset)
            try extractEntry(data, entry: entry, into: dst)

            offset = entry.nextOffset
            extracted += 1
        }
    }

    // MARK: - EOCD scan

    /// Find the End-of-Central-Directory record by scanning the
    /// last ~64 KB of the file backwards for the 0x06054b50 magic.
    /// Zip allows up to a 64 KB comment trailing the EOCD record,
    /// so we can't just check the last 22 bytes.
    private static func findEOCD(in data: Data) throws -> Int {
        let minOffset = max(0, data.count - 65_536 - 22)
        guard data.count >= 22 else {
            throw ExtractorError.invalidFormat("file too small to be a zip")
        }
        var i = data.count - 22
        while i >= minOffset {
            if readUInt32LE(data, at: i) == 0x06054b50 {
                return i
            }
            i -= 1
        }
        throw ExtractorError.invalidFormat("end-of-central-directory record not found")
    }

    // MARK: - Central Directory entry parsing

    /// Decoded view of a single central-directory entry. The fields
    /// we care about (compression method, sizes, filename, local
    /// header offset) + the offset where the NEXT CD entry starts
    /// so the iterator can advance.
    private struct CDEntry {
        let filename: String
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
        let nextOffset: Int
    }

    private static func parseCDEntry(_ data: Data, at offset: Int) throws -> CDEntry {
        let compressionMethod = readUInt16LE(data, at: offset + 10)
        let compressedSize = Int(readUInt32LE(data, at: offset + 20))
        let uncompressedSize = Int(readUInt32LE(data, at: offset + 24))
        let fnLen = Int(readUInt16LE(data, at: offset + 28))
        let extLen = Int(readUInt16LE(data, at: offset + 30))
        let cmtLen = Int(readUInt16LE(data, at: offset + 32))
        let localOffset = Int(readUInt32LE(data, at: offset + 42))

        let fnStart = offset + 46
        guard fnStart + fnLen <= data.count else {
            throw ExtractorError.invalidFormat("filename out of bounds at CD offset \(offset)")
        }
        // Filenames are UTF-8 (or, historically, CP437; modern zip
        // writers emit UTF-8 + set bit 11 of the general purpose
        // flag. The HTDemucs mlpackage zip uses only ASCII inside
        // a well-known directory tree, so UTF-8 decoding is safe).
        let nameData = data[fnStart..<(fnStart + fnLen)]
        let filename = String(data: nameData, encoding: .utf8) ?? ""
        if filename.isEmpty {
            throw ExtractorError.invalidFormat("empty entry filename")
        }

        return CDEntry(
            filename: filename,
            compressionMethod: compressionMethod,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize,
            localHeaderOffset: localOffset,
            nextOffset: fnStart + fnLen + extLen + cmtLen
        )
    }

    // MARK: - Per-entry extraction

    private static func extractEntry(
        _ data: Data,
        entry: CDEntry,
        into dst: URL
    ) throws {
        // Zip-slip protection — refuse parent-traversal + absolute
        // paths. A maliciously-crafted zip otherwise writes outside
        // `dst` (e.g. ../../../etc/whatever).
        if entry.filename.contains("..") || entry.filename.hasPrefix("/") {
            throw ExtractorError.unsafeEntryPath(entry.filename)
        }
        let destPath = dst.appendingPathComponent(entry.filename)

        // Directory entry (trailing slash in zip convention). Just
        // create the dir + move on.
        if entry.filename.hasSuffix("/") {
            try FileManager.default.createDirectory(
                at: destPath, withIntermediateDirectories: true
            )
            return
        }

        // Find the data bytes via the local file header. The local
        // header has its own filename + extra-field lengths which
        // can differ from the central directory's, so we MUST read
        // them from the local header itself.
        let lh = entry.localHeaderOffset
        guard lh + 30 <= data.count else {
            throw ExtractorError.invalidFormat("local header out of bounds at \(lh)")
        }
        let lhSig = readUInt32LE(data, at: lh)
        guard lhSig == 0x04034b50 else {
            throw ExtractorError.invalidFormat(
                "bad local header signature at \(lh): 0x\(String(lhSig, radix: 16))"
            )
        }
        let lhFnLen = Int(readUInt16LE(data, at: lh + 26))
        let lhExtLen = Int(readUInt16LE(data, at: lh + 28))
        let dataOffset = lh + 30 + lhFnLen + lhExtLen
        guard dataOffset + entry.compressedSize <= data.count else {
            throw ExtractorError.invalidFormat(
                "data range out of bounds for \(entry.filename)"
            )
        }

        // Slice + decompress
        let compressed = data[dataOffset..<(dataOffset + entry.compressedSize)]
        let decompressed: Data
        switch entry.compressionMethod {
        case 0:
            // STORE — bytes are already raw. Re-wrap in a 0-based
            // Data so the caller doesn't have to worry about slice
            // indexing.
            decompressed = Data(compressed)
        case 8:
            decompressed = try inflate(Data(compressed), expectedSize: entry.uncompressedSize)
        default:
            throw ExtractorError.unsupportedCompression(entry.compressionMethod)
        }

        // Create parent directory if missing, then write the file.
        try FileManager.default.createDirectory(
            at: destPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try decompressed.write(to: destPath, options: .atomic)
        } catch {
            throw ExtractorError.writeFailed(destPath, error)
        }
    }

    // MARK: - DEFLATE decompression

    /// Decompress raw-DEFLATE bytes via Apple's Compression
    /// framework. Despite the constant's name,
    /// `COMPRESSION_ZLIB` decodes raw DEFLATE (no zlib header /
    /// adler32 trailer) — which IS what zip uses (RFC 1951).
    private static func inflate(_ data: Data, expectedSize: Int) throws -> Data {
        // Allocate the exact decompressed buffer. Compression
        // framework writes directly into it and returns the byte
        // count actually written; we verify it matches the zip
        // entry's uncompressed-size field.
        var result = Data(count: expectedSize)
        let n: Int = result.withUnsafeMutableBytes { dstBytes in
            data.withUnsafeBytes { srcBytes in
                guard let srcPtr = srcBytes.bindMemory(to: UInt8.self).baseAddress,
                      let dstPtr = dstBytes.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    dstPtr, expectedSize,
                    srcPtr, data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard n == expectedSize else {
            throw ExtractorError.decompressionFailed(
                "expected \(expectedSize) bytes, got \(n)"
            )
        }
        return result
    }

    // MARK: - Little-endian readers
    //
    // Zip is little-endian throughout. macOS is also little-endian,
    // so theoretically a direct memcpy would work; but explicit
    // bit-shifting reads are clearer + safe at any alignment.

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        let lo = UInt16(data[data.startIndex + offset])
        let hi = UInt16(data[data.startIndex + offset + 1])
        return lo | (hi << 8)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let b0 = UInt32(data[data.startIndex + offset])
        let b1 = UInt32(data[data.startIndex + offset + 1])
        let b2 = UInt32(data[data.startIndex + offset + 2])
        let b3 = UInt32(data[data.startIndex + offset + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }
}
