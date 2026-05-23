//
//  DemucsModelInstaller.swift
//  pocket-tts-macos
//
//  Stateless I/O helpers split out of `DemucsModelManager` so the
//  @MainActor coordinator stays focused on observed state + the
//  download lifecycle, while the disk-side machinery (SHA verify,
//  zip extraction via `DemucsZipExtractor`, atomic move into the
//  versioned install dir) lives here as a nonisolated enum of
//  static functions.
//
//  These functions are pure I/O — no shared state, no actor hops,
//  no UI bindings. The split also makes the verify / install math
//  unit-testable without instantiating the @MainActor manager: a
//  test can build a synthetic zip in `NSTemporaryDirectory()`,
//  invoke `install`, and assert the post-state. That doesn't yet
//  give us URL-mocked download tests (those still need the manager
//  to drive the backoff loop), but it removes a big chunk of code
//  that wasn't actor-isolated for any real reason.

import CryptoKit
import Foundation

// MARK: - DemucsModelInstaller

nonisolated enum DemucsModelInstaller {

    // MARK: - Errors

    enum InstallerError: Error, CustomStringConvertible {
        case shaMismatch(expected: String, actual: String)
        case zipMissingExpectedInner(String)
        case unzipFailed(Error)
        case moveFailed(Error)

        var description: String {
            switch self {
            case .shaMismatch(let exp, let got):
                return "SHA256 \(got) didn't match expected \(exp)"
            case .zipMissingExpectedInner(let name):
                return "extracted zip missing \(name) at root"
            case .unzipFailed(let e):
                return "unzip failed: \(e.localizedDescription)"
            case .moveFailed(let e):
                return "atomic move failed: \(e.localizedDescription)"
            }
        }
    }

    // MARK: - SHA verification

    /// Streaming SHA256 of `file` (16 KB blocks) compared against
    /// the lowercase-hex `expectedSHA`. Streaming because the
    /// HTDemucs zip is 287 MB — loading it into RAM just to hash
    /// would blow the working set for no reason. Throws
    /// `.shaMismatch` on inequality; the caller is responsible for
    /// purging the staging dir.
    static func verifySHA(_ file: URL, expectedSHA: String) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        let actual = digest.map { String(format: "%02x", $0) }.joined()
        guard actual == expectedSHA else {
            throw InstallerError.shaMismatch(expected: expectedSHA, actual: actual)
        }
    }

    // MARK: - Install

    /// Unzip + atomic-move `stagingZip` into `<installedDir>/<variant
    /// installedFolderName>/<variant>.mlpackage`. On any failure
    /// the partial install dir is removed so the user can retry
    /// without "this folder already exists" errors.
    ///
    /// Returns the final mlpackage URL.
    static func install(
        stagingZip: URL,
        stagingDir: URL,
        installedDir: URL,
        variant: DemucsModelVariant
    ) throws -> URL {
        let finalDir = installedDir.appendingPathComponent(
            variant.installedFolderName, isDirectory: true
        )
        let tempUnzipDir = stagingDir.appendingPathComponent(
            "unzip-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: tempUnzipDir) }

        do {
            try FileManager.default.createDirectory(
                at: tempUnzipDir, withIntermediateDirectories: true
            )
            try unzip(stagingZip, into: tempUnzipDir)
        } catch let e as InstallerError {
            throw e
        } catch {
            throw InstallerError.unzipFailed(error)
        }

        // The published zip MUST contain `<rawValue>.mlpackage/` at
        // its root. Look for it explicitly so a mis-shaped zip
        // (rare, but possible if HF reuploads with different
        // layout) fails loudly here instead of at MLModel load.
        let expectedInner = "\(variant.rawValue).mlpackage"
        let extractedInner = tempUnzipDir.appendingPathComponent(expectedInner)
        guard FileManager.default.fileExists(atPath: extractedInner.path) else {
            throw InstallerError.zipMissingExpectedInner(expectedInner)
        }

        do {
            // Atomic-ish: if `finalDir` already exists (failed
            // prior install), nuke it so the move can land.
            if FileManager.default.fileExists(atPath: finalDir.path) {
                try FileManager.default.removeItem(at: finalDir)
            }
            try FileManager.default.createDirectory(
                at: finalDir, withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(
                at: extractedInner,
                to: finalDir.appendingPathComponent(expectedInner)
            )
        } catch {
            try? FileManager.default.removeItem(at: finalDir)
            throw InstallerError.moveFailed(error)
        }
        return finalDir.appendingPathComponent(expectedInner)
    }

    // MARK: - Unzip

    /// Extract `src` into `dst` via the in-process
    /// `DemucsZipExtractor`. No subprocess spawn — earlier revisions
    /// invoked `/usr/bin/unzip` via `Process()` but that's hostile
    /// to App Sandbox and the project's notarization plans.
    private static func unzip(_ src: URL, into dst: URL) throws {
        try DemucsZipExtractor.extract(src, into: dst)
    }
}
