/// JSON data model used for canonicalization and hashing.
///
/// Integers and doubles are distinct cases because RFC 8785 formats them
/// differently and Morningstar's hash contents mix both. A tiny built-in
/// parser (`JSONValue.parse`) is provided instead of Foundation's
/// JSONSerialization so int/double discrimination and -0.0 survival are
/// deterministic and identical on every platform.

import Foundation

public indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

public extension JSONValue {
    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

public enum JSONParseError: Error, Equatable {
    case unexpectedCharacter(String)
    case unexpectedEnd
    case invalidNumber(String)
    case invalidEscape(String)
}

extension JSONValue {
    /// Minimal recursive-descent JSON parser producing `JSONValue`.
    /// A number is `.int` iff it has no fraction, no exponent, and fits
    /// Int64; otherwise `.double` (so `-0.0`, `1.0`, and `1e21` keep the
    /// type their spelling implies).
    public static func parse(_ text: String) throws -> JSONValue {
        var scalars = Array(text.unicodeScalars)
        var i = 0
        let value = try parseValue(&scalars, &i)
        skipWhitespace(&scalars, &i)
        guard i == scalars.count else {
            throw JSONParseError.unexpectedCharacter("trailing content at \(i)")
        }
        return value
    }

    private static func skipWhitespace(_ s: inout [Unicode.Scalar], _ i: inout Int) {
        while i < s.count, s[i] == " " || s[i] == "\t" || s[i] == "\n" || s[i] == "\r" {
            i += 1
        }
    }

    private static func expect(_ literal: String, _ s: inout [Unicode.Scalar], _ i: inout Int) throws {
        for ch in literal.unicodeScalars {
            guard i < s.count, s[i] == ch else { throw JSONParseError.unexpectedCharacter(literal) }
            i += 1
        }
    }

    private static func parseValue(_ s: inout [Unicode.Scalar], _ i: inout Int) throws -> JSONValue {
        skipWhitespace(&s, &i)
        guard i < s.count else { throw JSONParseError.unexpectedEnd }
        switch s[i] {
        case "n": try expect("null", &s, &i); return .null
        case "t": try expect("true", &s, &i); return .bool(true)
        case "f": try expect("false", &s, &i); return .bool(false)
        case "\"": return .string(try parseString(&s, &i))
        case "[":
            i += 1
            var items: [JSONValue] = []
            skipWhitespace(&s, &i)
            if i < s.count, s[i] == "]" { i += 1; return .array(items) }
            while true {
                items.append(try parseValue(&s, &i))
                skipWhitespace(&s, &i)
                guard i < s.count else { throw JSONParseError.unexpectedEnd }
                if s[i] == "," { i += 1; continue }
                if s[i] == "]" { i += 1; return .array(items) }
                throw JSONParseError.unexpectedCharacter("in array at \(i)")
            }
        case "{":
            i += 1
            var object: [String: JSONValue] = [:]
            skipWhitespace(&s, &i)
            if i < s.count, s[i] == "}" { i += 1; return .object(object) }
            while true {
                skipWhitespace(&s, &i)
                let key = try parseString(&s, &i)
                skipWhitespace(&s, &i)
                guard i < s.count, s[i] == ":" else { throw JSONParseError.unexpectedCharacter("expected ':'") }
                i += 1
                object[key] = try parseValue(&s, &i)
                skipWhitespace(&s, &i)
                guard i < s.count else { throw JSONParseError.unexpectedEnd }
                if s[i] == "," { i += 1; continue }
                if s[i] == "}" { i += 1; return .object(object) }
                throw JSONParseError.unexpectedCharacter("in object at \(i)")
            }
        default:
            return try parseNumber(&s, &i)
        }
    }

    private static func parseString(_ s: inout [Unicode.Scalar], _ i: inout Int) throws -> String {
        guard i < s.count, s[i] == "\"" else { throw JSONParseError.unexpectedCharacter("expected string") }
        i += 1
        var out = ""
        while true {
            guard i < s.count else { throw JSONParseError.unexpectedEnd }
            let c = s[i]
            if c == "\"" { i += 1; return out }
            if c == "\\" {
                i += 1
                guard i < s.count else { throw JSONParseError.unexpectedEnd }
                switch s[i] {
                case "\"": out.unicodeScalars.append("\""); i += 1
                case "\\": out.unicodeScalars.append("\\"); i += 1
                case "/": out.unicodeScalars.append("/"); i += 1
                case "b": out.unicodeScalars.append("\u{08}"); i += 1
                case "f": out.unicodeScalars.append("\u{0C}"); i += 1
                case "n": out.unicodeScalars.append("\n"); i += 1
                case "r": out.unicodeScalars.append("\r"); i += 1
                case "t": out.unicodeScalars.append("\t"); i += 1
                case "u":
                    i += 1
                    let hi = try parseHex4(&s, &i)
                    if (0xD800...0xDBFF).contains(hi) {
                        try expect("\\u", &s, &i)
                        let lo = try parseHex4(&s, &i)
                        guard (0xDC00...0xDFFF).contains(lo) else {
                            throw JSONParseError.invalidEscape("unpaired surrogate")
                        }
                        let code = 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)
                        out.unicodeScalars.append(Unicode.Scalar(code)!)
                    } else if (0xDC00...0xDFFF).contains(hi) {
                        throw JSONParseError.invalidEscape("lone low surrogate")
                    } else {
                        out.unicodeScalars.append(Unicode.Scalar(hi)!)
                    }
                default:
                    throw JSONParseError.invalidEscape(String(s[i]))
                }
            } else {
                out.unicodeScalars.append(c)
                i += 1
            }
        }
    }

    private static func parseHex4(_ s: inout [Unicode.Scalar], _ i: inout Int) throws -> Int {
        var value = 0
        for _ in 0..<4 {
            guard i < s.count, let digit = s[i].hexDigitValue else {
                throw JSONParseError.invalidEscape("bad \\u escape")
            }
            value = value * 16 + digit
            i += 1
        }
        return value
    }

    private static func parseNumber(_ s: inout [Unicode.Scalar], _ i: inout Int) throws -> JSONValue {
        let start = i
        var sawFraction = false
        var sawExponent = false
        if i < s.count, s[i] == "-" { i += 1 }
        while i < s.count {
            let c = s[i]
            if ("0"..."9").contains(c) { i += 1; continue }
            if c == "." { sawFraction = true; i += 1; continue }
            if c == "e" || c == "E" { sawExponent = true; i += 1; continue }
            if c == "+" || c == "-", i > start, s[i-1] == "e" || s[i-1] == "E" { i += 1; continue }
            break
        }
        var text = ""
        text.unicodeScalars.append(contentsOf: s[start..<i])
        guard !text.isEmpty, text != "-" else { throw JSONParseError.invalidNumber(text) }
        if !sawFraction && !sawExponent, let n = Int64(text) {
            return .int(n)
        }
        guard let d = Double(text) else { throw JSONParseError.invalidNumber(text) }
        return .double(d)
    }
}

private extension Unicode.Scalar {
    var hexDigitValue: Int? {
        switch self {
        case "0"..."9": return Int(value - 0x30)
        case "a"..."f": return Int(value - 0x61 + 10)
        case "A"..."F": return Int(value - 0x41 + 10)
        default: return nil
        }
    }
}
