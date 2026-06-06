//
//  JSONExtractorTests.swift
//  mimika-ai-voice-studioTests
//
//  Tolerant extraction of the first balanced JSON object from chatty model
//  output: leading prose, markdown fences, trailing commentary, braces inside
//  string values, and nested objects.
//

import XCTest
@testable import mimika_ai_voice_studio

final class JSONExtractorTests: XCTestCase {

    private struct Sample: Codable, Equatable {
        let a: String
        let b: Int
    }

    func test_extractsPlainObject() throws {
        let s = try JSONExtractor.decode(Sample.self, from: #"{"a":"x","b":1}"#)
        XCTAssertEqual(s, Sample(a: "x", b: 1))
    }

    func test_ignoresLeadingProse() throws {
        let s = try JSONExtractor.decode(Sample.self, from: #"Sure! Here you go: {"a":"x","b":1}"#)
        XCTAssertEqual(s.a, "x")
    }

    func test_ignoresMarkdownFencesAndTrailingProse() throws {
        let raw = "```json\n{\"a\":\"y\",\"b\":2}\n```\nHope that helps!"
        let s = try JSONExtractor.decode(Sample.self, from: raw)
        XCTAssertEqual(s, Sample(a: "y", b: 2))
    }

    func test_handlesBracesInsideStringValues() throws {
        let s = try JSONExtractor.decode(Sample.self, from: #"{"a":"a } b { c","b":3}"#)
        XCTAssertEqual(s, Sample(a: "a } b { c", b: 3))
    }

    func test_handlesNestedObjects() throws {
        struct Nested: Codable { let outer: Sample }
        let n = try JSONExtractor.decode(Nested.self, from: #"prefix {"outer":{"a":"z","b":4}} suffix"#)
        XCTAssertEqual(n.outer.b, 4)
    }

    func test_throwsWhenNoObject() {
        XCTAssertThrowsError(try JSONExtractor.extractObject(from: "no json at all"))
    }

    func test_repairsTruncatedObject() throws {
        struct P: Codable, Equatable { let name: String; let bio: String? }
        // Model hit EOS mid-string: missing closing quote + brace.
        let raw = #"{"name":"Ada","bio":"a dry engineer who"#
        let p = try JSONExtractor.decode(P.self, from: raw)
        XCTAssertEqual(p, P(name: "Ada", bio: "a dry engineer who"))
    }

    func test_repairsTruncatedNestedArray() throws {
        struct Cast: Codable { let cast: [String] }
        // Truncated mid-array element.
        let raw = #"{"cast":["Ada","Bert"#
        let c = try JSONExtractor.decode(Cast.self, from: raw)
        XCTAssertEqual(c.cast, ["Ada", "Bert"])
    }
}
