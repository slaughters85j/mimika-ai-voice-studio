//
//  DictationControllerTests.swift
//  mimika-ai-voice-studioTests
//
//  Unit-test surface for DictationController is limited — the real mic +
//  speech-recognition pipeline requires user permission grants we can't
//  fully exercise from XCTest. What we CAN verify:
//
//    * init lands in .notDetermined
//    * start() throws .notAuthorized when authState hasn't been set
//      (proves we don't blindly access audioEngine.inputNode without
//      checking — the AVAudioEngine misuse that caused the prior crash)
//    * The AuthState / DictationError enums behave as values
//
//  The end-to-end "click mic → speak → text appears" path is covered by
//  ChatMicUITests.swift, which is also where regressions in the crash
//  itself would surface (a process death during the click is a test
//  failure).

import XCTest
@testable import mimika_ai_voice_studio

@MainActor
final class DictationControllerTests: XCTestCase {

    func test_init_authStateIsNotDetermined() {
        let controller = DictationController()
        XCTAssertEqual(controller.authState, .notDetermined)
    }

    func test_start_withoutAuth_throwsNotAuthorized() {
        let controller = DictationController()
        XCTAssertThrowsError(try controller.start()) { error in
            guard let err = error as? DictationController.DictationError else {
                XCTFail("expected DictationError; got \(error)")
                return
            }
            switch err {
            case .notAuthorized: break // expected
            default: XCTFail("expected .notAuthorized; got \(err)")
            }
        }
    }

    func test_authState_equality_acrossCases() {
        XCTAssertEqual(DictationController.AuthState.notDetermined, .notDetermined)
        XCTAssertEqual(DictationController.AuthState.authorized, .authorized)
        XCTAssertEqual(DictationController.AuthState.denied, .denied)
        XCTAssertEqual(DictationController.AuthState.restricted, .restricted)
        XCTAssertEqual(DictationController.AuthState.unavailable("x"),
                       DictationController.AuthState.unavailable("x"))
        XCTAssertNotEqual(DictationController.AuthState.unavailable("a"),
                          DictationController.AuthState.unavailable("b"))
    }

    func test_stopAndCancel_areSafeBeforeStart() {
        // Should not crash even though we never started.
        let controller = DictationController()
        controller.stop()
        controller.cancel()
    }
}
