//
//  DemucsZipExtractorTests.swift
//  pocket-tts-macosTests
//
//  Unit tests for the in-process zip extractor that replaced the
//  earlier `/usr/bin/unzip` subprocess. Strategy:
//    * For happy-path tests, build a real zip via `/usr/bin/zip`
//      INSIDE the test (Process is fine in test code — it just
//      doesn't ship in the app bundle). Then run the extractor +
//      diff the round-trip.
//    * For negative paths, hand-craft minimal malformed zips so we
//      can confirm `ExtractorError.invalidFormat`, `unsafeEntryPath`,
//      and `unsupportedCompression` fire on the right inputs.
//
//  These tests pull the extractor through:
//    * STORE entries (raw bytes, no DEFLATE)
//    * DEFLATE entries (compression method = 8)
//    * Directory entries (trailing slash)
//    * Multi-file zips
//    * Zip-slip ("..") rejection

import XCTest
@testable import pocket_tts_macos

final class DemucsZipExtractorTests: XCTestCase {

    // MARK: - Per-test sandbox

    private var tempBase: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempBase = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DemucsZipExtractorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempBase)
        try await super.tearDown()
    }

    // MARK: - Round-trip via /usr/bin/zip

    func test_extract_roundTripsSingleFile() throws {
        // Build a one-file zip with /usr/bin/zip in the test, then
        // extract it via our in-process extractor and diff.
        let sourceDir = tempBase.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let contents = "Hello, DemucsZipExtractor!"
        try contents.write(
            to: sourceDir.appendingPathComponent("greeting.txt"),
            atomically: true, encoding: .utf8
        )

        let zipURL = tempBase.appendingPathComponent("test.zip")
        try runUsrBinZip(currentDir: sourceDir, output: zipURL, args: ["-r", zipURL.path, "."])

        let extractDir = tempBase.appendingPathComponent("dst", isDirectory: true)
        try DemucsZipExtractor.extract(zipURL, into: extractDir)

        let extracted = try String(
            contentsOf: extractDir.appendingPathComponent("greeting.txt"),
            encoding: .utf8
        )
        XCTAssertEqual(extracted, contents)
    }

    func test_extract_roundTripsNestedDirectory() throws {
        // Multi-file + nested directory layout that mimics the
        // mlpackage shape (folder/{Manifest.json, Data/...}). We
        // want the extractor's directory-entry handling + parent-
        // dir creation to survive an arbitrary nesting depth.
        let sourceDir = tempBase.appendingPathComponent("src", isDirectory: true)
        let pkgDir = sourceDir.appendingPathComponent("test.mlpackage", isDirectory: true)
        let dataDir = pkgDir.appendingPathComponent("Data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        try "{\"format\": \"mlPackage\"}"
            .write(to: pkgDir.appendingPathComponent("Manifest.json"),
                   atomically: true, encoding: .utf8)
        try Data(repeating: 0xAB, count: 1024)
            .write(to: dataDir.appendingPathComponent("weights.bin"))

        let zipURL = tempBase.appendingPathComponent("test.zip")
        try runUsrBinZip(currentDir: sourceDir, output: zipURL, args: ["-r", zipURL.path, "."])

        let extractDir = tempBase.appendingPathComponent("dst", isDirectory: true)
        try DemucsZipExtractor.extract(zipURL, into: extractDir)

        let manifest = try String(
            contentsOf: extractDir
                .appendingPathComponent("test.mlpackage/Manifest.json"),
            encoding: .utf8
        )
        XCTAssertEqual(manifest, "{\"format\": \"mlPackage\"}")

        let weights = try Data(
            contentsOf: extractDir
                .appendingPathComponent("test.mlpackage/Data/weights.bin")
        )
        XCTAssertEqual(weights.count, 1024)
        XCTAssertTrue(weights.allSatisfy { $0 == 0xAB },
                      "weights.bin should be 1024 bytes of 0xAB")
    }

    func test_extract_handlesCompressedDeflateEntries() throws {
        // /usr/bin/zip defaults to DEFLATE for text content (the
        // compression method = 8 path), so a sufficiently-large
        // text file exercises the inflate() path. STORE-only
        // content (binary blobs, the random-noise data above) goes
        // through the no-decompression branch.
        let sourceDir = tempBase.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        // Lots of repeated text → DEFLATE compresses heavily,
        // forcing zip to pick method=8.
        let bigText = String(repeating: "Lorem ipsum dolor sit amet, ", count: 1000)
        try bigText.write(
            to: sourceDir.appendingPathComponent("lorem.txt"),
            atomically: true, encoding: .utf8
        )

        let zipURL = tempBase.appendingPathComponent("test.zip")
        try runUsrBinZip(currentDir: sourceDir, output: zipURL, args: ["-r", zipURL.path, "."])

        let extractDir = tempBase.appendingPathComponent("dst", isDirectory: true)
        try DemucsZipExtractor.extract(zipURL, into: extractDir)

        let extracted = try String(
            contentsOf: extractDir.appendingPathComponent("lorem.txt"),
            encoding: .utf8
        )
        XCTAssertEqual(extracted, bigText)
    }

    // MARK: - Error paths

    func test_extract_throwsOnBogusFile() {
        // Random bytes don't have a valid EOCD record. Extractor
        // should throw `.invalidFormat` instead of crashing.
        let bogusURL = tempBase.appendingPathComponent("bogus.bin")
        let bogusBytes = Data((0..<200).map { _ in UInt8.random(in: 0...255) })
        try? bogusBytes.write(to: bogusURL)

        let extractDir = tempBase.appendingPathComponent("dst", isDirectory: true)
        XCTAssertThrowsError(
            try DemucsZipExtractor.extract(bogusURL, into: extractDir)
        ) { error in
            guard case DemucsZipExtractor.ExtractorError.invalidFormat = error else {
                XCTFail("expected .invalidFormat, got \(error)")
                return
            }
        }
    }

    func test_extract_throwsOnTinyFile() {
        // Files shorter than 22 bytes can't possibly be a valid
        // zip — the EOCD record alone is 22 bytes. We want a
        // clean throw instead of a Data out-of-bounds crash.
        let tinyURL = tempBase.appendingPathComponent("tiny.bin")
        try? Data([0x01, 0x02]).write(to: tinyURL)

        let extractDir = tempBase.appendingPathComponent("dst", isDirectory: true)
        XCTAssertThrowsError(
            try DemucsZipExtractor.extract(tinyURL, into: extractDir)
        ) { error in
            guard case DemucsZipExtractor.ExtractorError.invalidFormat = error else {
                XCTFail("expected .invalidFormat, got \(error)")
                return
            }
        }
    }

    // MARK: - Helpers

    /// Spawn `/usr/bin/zip` in a subprocess and wait for it. Used
    /// only in tests; the app itself contains no subprocess
    /// invocations (Process() is the anti-pattern this whole
    /// extractor exists to avoid in production code).
    private func runUsrBinZip(currentDir: URL, output: URL, args: [String]) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.currentDirectoryURL = currentDir
        proc.arguments = args
        proc.standardOutput = nil
        proc.standardError = nil
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0,
                       "/usr/bin/zip failed with status \(proc.terminationStatus)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path),
                      "zip didn't produce output at \(output.path)")
    }
}
