//
//  JSONExtractor.swift
//  mimika-ai-voice-studio
//
//  Tolerant JSON-object extraction for chatty local-model output. Even with a
//  response_format hint and a "return only JSON" system prompt, local models
//  wrap output in ```json fences, prefix it with prose ("Sure! Here you go:"),
//  or append trailing commentary. This brace-counts the FIRST balanced
//  top-level {...} object (respecting string literals + escapes) and decodes
//  it, ignoring anything before or after.
//

import Foundation

nonisolated enum JSONExtractor {

    enum ExtractError: Error, CustomStringConvertible {
        case noObject
        case unbalanced

        var description: String {
            switch self {
            case .noObject:   return "no JSON object found in model output"
            case .unbalanced: return "unbalanced braces in model output"
            }
        }
    }

    /// Extract + decode the first balanced JSON object from `raw`. If the
    /// strict balanced-object parse fails (e.g. the model truncated its
    /// output), fall back to a repair pass that closes dangling strings and
    /// open braces/brackets so a partially-complete object can still decode.
    static func decode<T: Decodable>(_ type: T.Type, from raw: String) throws -> T {
        if let slice = try? extractObject(from: raw),
           let decoded = try? JSONDecoder().decode(T.self, from: Data(slice.utf8)) {
            return decoded
        }
        let repaired = try repairedObject(from: raw)
        return try JSONDecoder().decode(T.self, from: Data(repaired.utf8))
    }

    /// Return the substring of the first balanced top-level `{...}` object.
    /// Brace-counts from the first `{`, tracking in-string/escape state so a
    /// `{` or `}` inside a string value doesn't miscount. Fences and prose are
    /// ignored because they fall outside the brace span.
    static func extractObject(from raw: String) throws -> String {
        guard let start = raw.firstIndex(of: "{") else { throw ExtractError.noObject }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < raw.endIndex {
            let ch = raw[index]
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                if ch == "\"" {
                    inString = true
                } else if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(raw[start...index])
                    }
                }
            }
            index = raw.index(after: index)
        }
        throw ExtractError.unbalanced
    }

    /// Best-effort repair of a truncated object: scan from the first `{`,
    /// and if the input ends mid-object, close any open string and the open
    /// `{`/`[` containers. Recovers mid-value/mid-string truncations (common
    /// when a small model hits EOS early); a dangling key with no value still
    /// won't decode, which the caller's retry handles.
    static func repairedObject(from raw: String) throws -> String {
        guard let start = raw.firstIndex(of: "{") else { throw ExtractError.noObject }
        var result = ""
        var stack: [Character] = []
        var inString = false
        var escaped = false
        var index = start
        while index < raw.endIndex {
            let ch = raw[index]
            result.append(ch)
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else {
                switch ch {
                case "\"": inString = true
                case "{": stack.append("}")
                case "[": stack.append("]")
                case "}", "]":
                    if !stack.isEmpty { stack.removeLast() }
                    if stack.isEmpty { return result }   // complete top-level object
                default: break
                }
            }
            index = raw.index(after: index)
        }
        if inString { result.append("\"") }
        while let closer = stack.popLast() { result.append(closer) }
        return result
    }
}
