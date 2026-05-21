//
//  WhisperModelManagerTests.swift
//  pocket-tts-macosTests
//
//  Catalog + identifier tests for WhisperModelVariant. Manager-level
//  download / delete tests are intentionally omitted — they require
//  network access + real Whisper model files on disk, which makes
//  them brittle in CI and slow locally. The manager surface
//  (download / delete / setActive / rescan) is verified manually via
//  the Voice Changer's "Manage Models" sub-sheet.

import XCTest
@testable import pocket_tts_macos

final class WhisperModelVariantTests: XCTestCase {

    // MARK: - Catalog

    func test_variantCount() {
        // 4 English-only (tiny/base/small/medium.en) +
        // 5 multilingual (tiny/base/small/medium + large-v3) = 9.
        XCTAssertEqual(WhisperModelVariant.allCases.count, 9)
    }

    func test_englishOnlyCount() {
        XCTAssertEqual(
            WhisperModelVariant.allCases.filter(\.isEnglishOnly).count,
            4
        )
    }

    func test_multilingualCount() {
        XCTAssertEqual(
            WhisperModelVariant.allCases.filter { !$0.isEnglishOnly }.count,
            5
        )
    }

    // MARK: - Identifiers

    func test_whisperKitIdentifiersUnique() {
        let ids = WhisperModelVariant.allCases.map(\.whisperKitIdentifier)
        XCTAssertEqual(Set(ids).count, ids.count,
                       "Every variant must produce a unique WhisperKit identifier")
    }

    func test_identifierFormat() {
        XCTAssertEqual(WhisperModelVariant.tinyEn.whisperKitIdentifier,   "openai_whisper-tiny.en")
        XCTAssertEqual(WhisperModelVariant.baseEn.whisperKitIdentifier,   "openai_whisper-base.en")
        XCTAssertEqual(WhisperModelVariant.smallEn.whisperKitIdentifier,  "openai_whisper-small.en")
        XCTAssertEqual(WhisperModelVariant.mediumEn.whisperKitIdentifier, "openai_whisper-medium.en")
        XCTAssertEqual(WhisperModelVariant.tiny.whisperKitIdentifier,     "openai_whisper-tiny")
        XCTAssertEqual(WhisperModelVariant.base.whisperKitIdentifier,     "openai_whisper-base")
        XCTAssertEqual(WhisperModelVariant.small.whisperKitIdentifier,    "openai_whisper-small")
        XCTAssertEqual(WhisperModelVariant.medium.whisperKitIdentifier,   "openai_whisper-medium")
        XCTAssertEqual(WhisperModelVariant.largeV3.whisperKitIdentifier,  "openai_whisper-large-v3")
    }

    func test_rawValueRoundTrip() {
        for v in WhisperModelVariant.allCases {
            XCTAssertEqual(
                WhisperModelVariant(rawValue: v.rawValue),
                v,
                "Round-trip failed for \(v.rawValue)"
            )
        }
    }

    // MARK: - English-only flag

    func test_isEnglishOnlyMatchesSuffix() {
        for v in WhisperModelVariant.allCases {
            XCTAssertEqual(
                v.isEnglishOnly,
                v.rawValue.hasSuffix(".en"),
                "isEnglishOnly should match the `.en` suffix for \(v.rawValue)"
            )
        }
    }

    func test_englishOnlyVariantsHintLanguage() {
        for v in WhisperModelVariant.allCases where v.isEnglishOnly {
            XCTAssertEqual(v.languageHint, "en",
                           "English-only \(v) should hint 'en' to skip language detection")
        }
    }

    func test_multilingualVariantsHaveNoLanguageHint() {
        for v in WhisperModelVariant.allCases where !v.isEnglishOnly {
            XCTAssertNil(v.languageHint,
                         "Multilingual \(v) should let WhisperKit auto-detect language (nil)")
        }
    }

    // MARK: - UI strings

    func test_allVariantsHavePopulatedUIStrings() {
        for v in WhisperModelVariant.allCases {
            XCTAssertFalse(v.displayName.isEmpty,    "\(v) missing displayName")
            XCTAssertFalse(v.approxSize.isEmpty,     "\(v) missing approxSize")
            XCTAssertFalse(v.speedDescription.isEmpty, "\(v) missing speedDescription")
            XCTAssertFalse(v.recommendedFor.isEmpty, "\(v) missing recommendedFor")
        }
    }

    func test_recommendedFlag() {
        // Exactly two recommendations — one English (baseEn), one
        // multilingual (base). Other variants are explicit choices.
        let recommended = WhisperModelVariant.allCases.filter(\.isRecommended)
        XCTAssertEqual(Set(recommended), [.baseEn, .base])
    }
}
