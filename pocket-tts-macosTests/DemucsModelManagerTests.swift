//
//  DemucsModelManagerTests.swift
//  pocket-tts-macosTests
//
//  Lifecycle tests for `DemucsModelManager` that don't touch the
//  real HuggingFace endpoint or write to the user's container.
//  Strategy:
//
//    1. Subclass `URLProtocol` to intercept the manager's
//       URLSession traffic and return canned responses
//       (`MockHTTPResponder`). This is the textbook way to test
//       URLSession-driven code without taking on the network.
//    2. Build the manager with a per-test temp `baseDir` and a
//       fast backoff policy, so each test runs in isolation and
//       takes < 1 s of wall clock.
//    3. Assert observable post-conditions:
//       - SHA mismatch → manager throws + staging dir is empty
//       - Three-step backoff retry → exactly N attempts visible
//         in `MockHTTPResponder.requestCount`
//       - Manually-placed mlpackage in `installed/htdemucs-v1/`
//         → `rescan()` registers it as downloaded
//
//  Out of scope here: the full download → unzip → MLModel path
//  (that's `DemucsSourceSeparatorParityTests`, which needs the
//  actual 80 MB mlpackage on disk and is skipped when missing).

import XCTest
@testable import pocket_tts_macos

@MainActor
final class DemucsModelManagerTests: XCTestCase {

    // MARK: - Per-test sandbox

    private var tempBase: URL!
    private var session: URLSession!

    override func setUp() async throws {
        try await super.setUp()
        // Each test gets a fresh temp dir so they don't fight over
        // staging/installed contents.
        tempBase = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DemucsModelManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)

        // URLSession with the mock protocol class registered. Using
        // `ephemeral` so nothing leaks into the system URL cache
        // between tests.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHTTPResponder.self]
        session = URLSession(configuration: config)

        MockHTTPResponder.reset()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempBase)
        MockHTTPResponder.reset()
        try await super.tearDown()
    }

    // MARK: - SHA mismatch cleanup

    func test_shaMismatch_throwsAndCleansStagingDir() async throws {
        // Respond once with "wrong" bytes so the SHA verify fails.
        // The download itself "succeeds" (200 + 16 bytes); it's
        // only the post-download SHA gate that triggers cleanup.
        MockHTTPResponder.enqueueSuccess(
            bytes: Data(repeating: 0xAB, count: 16),
            statusCode: 200
        )
        let manager = DemucsModelManager(
            urlSession: session,
            backoffPolicy: .none,    // no retries; one shot
            baseDir: tempBase
        )

        do {
            _ = try await manager.download(.htdemucs)
            XCTFail("expected SHA mismatch to throw")
        } catch DemucsModelManager.ManagerError.shaMismatch {
            // Pass — exactly the case we want.
        } catch {
            XCTFail("expected .shaMismatch, got \(error)")
        }

        // The staging dir should be empty afterwards. The
        // `runFullDownloadFlow`'s `defer` removes the staging zip;
        // no unzip ever ran so there's no unzip subdir either.
        let stagingDir = tempBase.appendingPathComponent("staging", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: stagingDir.path)) ?? []
        XCTAssertTrue(entries.isEmpty,
                      "staging dir should be empty after SHA-mismatch cleanup; got \(entries)")
        XCTAssertFalse(manager.downloaded.contains(.htdemucs),
                       "downloaded set must not register the failed variant")
    }

    // MARK: - Exponential-backoff retry

    func test_backoffRetryOn500_attemptsRequestedNumberOfTimes() async throws {
        // 500 / 500 / 500 → all attempts fail. Verify the manager
        // hit the endpoint exactly `delays.count + 1` times before
        // giving up.
        for _ in 0..<4 {
            MockHTTPResponder.enqueueSuccess(
                bytes: Data(),
                statusCode: 500
            )
        }
        let manager = DemucsModelManager(
            urlSession: session,
            backoffPolicy: .fast,    // 3 retries with ms-level sleep
            baseDir: tempBase
        )

        do {
            _ = try await manager.download(.htdemucs)
            XCTFail("expected 500 retries to ultimately fail")
        } catch DemucsModelManager.ManagerError.downloadFailed {
            // Pass.
        } catch {
            XCTFail("expected .downloadFailed, got \(error)")
        }

        // .fast policy has 3 retries → 4 total attempts.
        XCTAssertEqual(MockHTTPResponder.requestCount, 4,
                       "expected 4 attempts (1 initial + 3 retries)")
    }

    func test_backoffRetryOn500ThenRecovers_eventuallySucceedsThroughToSHACheck() async throws {
        // Two 500s, then a 200. We can't easily make the 3rd
        // response a *correctly-SHA'd* zip without checking in a
        // real fixture — but we CAN assert that the retry loop
        // surfaced the 200 (it would then fail at SHA verify, not
        // at the download step). That's still a meaningful
        // post-condition: the 3rd attempt's status reached SHA
        // verify, proving the retry loop didn't trip on the 500s.
        MockHTTPResponder.enqueueSuccess(bytes: Data(), statusCode: 500)
        MockHTTPResponder.enqueueSuccess(bytes: Data(), statusCode: 500)
        MockHTTPResponder.enqueueSuccess(
            bytes: Data(repeating: 0xCD, count: 32),
            statusCode: 200
        )
        let manager = DemucsModelManager(
            urlSession: session,
            backoffPolicy: .fast,
            baseDir: tempBase
        )

        do {
            _ = try await manager.download(.htdemucs)
            XCTFail("expected SHA mismatch after recovery from 500s")
        } catch DemucsModelManager.ManagerError.shaMismatch {
            // Pass — the 3rd attempt was a 200, SHA didn't match.
        } catch {
            XCTFail("expected .shaMismatch after retries succeeded, got \(error)")
        }

        // 2 × 500 + 1 × 200 = 3 attempts. Confirms backoff kicked
        // in twice but didn't fire a 4th time.
        XCTAssertEqual(MockHTTPResponder.requestCount, 3,
                       "expected 3 attempts (2 failures + 1 success-then-SHA-mismatch)")
    }

    // MARK: - Manual placement detection

    func test_manualPlacementOfMlpackage_isDetectedByRescan() throws {
        // Mimic a user dropping a pre-downloaded mlpackage into
        // `installed/htdemucs-v1/htdemucs.mlpackage/` from another
        // machine. The manager's `rescan()` should register the
        // variant as downloaded — no re-download, no SHA prompt.
        let manager = DemucsModelManager(
            urlSession: session,
            backoffPolicy: .fast,
            baseDir: tempBase
        )

        // Initially nothing on disk → downloaded set is empty.
        XCTAssertFalse(manager.downloaded.contains(.htdemucs))

        // Hand-craft the install layout.
        let mlpkgRoot = tempBase
            .appendingPathComponent("installed", isDirectory: true)
            .appendingPathComponent("htdemucs-v1", isDirectory: true)
            .appendingPathComponent("htdemucs.mlpackage", isDirectory: true)
        try FileManager.default.createDirectory(at: mlpkgRoot, withIntermediateDirectories: true)

        // mlpackages have at least a `Manifest.json` at root. The
        // manager's downloaded-ness check is "folder exists +
        // non-empty"; touching a sentinel file is enough.
        let sentinel = mlpkgRoot.appendingPathComponent("Manifest.json")
        try Data("{}".utf8).write(to: sentinel)

        manager.rescan()
        XCTAssertTrue(manager.downloaded.contains(.htdemucs),
                      "rescan() should detect a manually-placed mlpackage")
        XCTAssertEqual(manager.modelFolderURL(for: .htdemucs)?.path,
                       mlpkgRoot.path,
                       "modelFolderURL should point at the manually-placed mlpackage root")
    }

    // MARK: - Idempotent already-downloaded path

    func test_downloadShortCircuitsWhenAlreadyInstalled() async throws {
        // Pre-populate the install dir. The manager should return
        // the existing URL WITHOUT making any HTTP requests — a
        // no-op call to `download` shouldn't burn bandwidth.
        let mlpkgRoot = tempBase
            .appendingPathComponent("installed", isDirectory: true)
            .appendingPathComponent("htdemucs-v1", isDirectory: true)
            .appendingPathComponent("htdemucs.mlpackage", isDirectory: true)
        try FileManager.default.createDirectory(at: mlpkgRoot, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: mlpkgRoot.appendingPathComponent("Manifest.json"))

        let manager = DemucsModelManager(
            urlSession: session,
            backoffPolicy: .none,
            baseDir: tempBase
        )

        let url = try await manager.download(.htdemucs)
        XCTAssertEqual(url.path, mlpkgRoot.path)
        XCTAssertEqual(MockHTTPResponder.requestCount, 0,
                       "should NOT hit the network when already installed")
    }

    // MARK: - Delete

    func test_deleteRemovesInstalledFolder() throws {
        let mlpkgRoot = tempBase
            .appendingPathComponent("installed", isDirectory: true)
            .appendingPathComponent("htdemucs-v1", isDirectory: true)
            .appendingPathComponent("htdemucs.mlpackage", isDirectory: true)
        try FileManager.default.createDirectory(at: mlpkgRoot, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: mlpkgRoot.appendingPathComponent("Manifest.json"))

        let manager = DemucsModelManager(
            urlSession: session,
            backoffPolicy: .none,
            baseDir: tempBase
        )
        XCTAssertTrue(manager.downloaded.contains(.htdemucs))

        try manager.delete(.htdemucs)
        XCTAssertFalse(manager.downloaded.contains(.htdemucs))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempBase.appendingPathComponent("installed/htdemucs-v1").path
        ))
    }
}

// MARK: - Mock URLProtocol

/// Lightweight URLProtocol stub that holds a FIFO queue of canned
/// responses + counts how many times the manager's URLSession hit
/// the network. The test calls `enqueueSuccess(bytes:statusCode:)`
/// per expected attempt; each request consumes the head of the
/// queue. If the queue runs dry the request fails with
/// `URLError.cannotConnectToHost`.
final class MockHTTPResponder: URLProtocol {

    private struct Canned: Sendable {
        let data: Data
        let statusCode: Int
    }

    // MARK: - Static state (per-test)
    //
    // Singletons because URLProtocol is instantiated by URLSession,
    // not by the test code — we can't inject a per-test queue
    // through init. The TestCase's `setUp` calls `reset()`.

    nonisolated(unsafe) private static var queue: [Canned] = []
    nonisolated(unsafe) private(set) static var requestCount: Int = 0
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        queue.removeAll()
        requestCount = 0
    }

    static func enqueueSuccess(bytes: Data, statusCode: Int) {
        lock.lock()
        defer { lock.unlock() }
        queue.append(Canned(data: bytes, statusCode: statusCode))
    }

    // MARK: - URLProtocol overrides

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requestCount += 1
        let canned = Self.queue.isEmpty ? nil : Self.queue.removeFirst()
        Self.lock.unlock()

        guard let canned else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: canned.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(canned.data.count)"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: canned.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        // Nothing to clean up — we're synchronous.
    }
}
