/// RFC 8785 (JSON Canonicalization Scheme) — Morningstar protocol 0.2.
///
/// This is a line-for-line port of the algorithm in the Python reference
/// implementation (`morningstar/canonical.py`): UTF-8 output, object keys
/// sorted by UTF-16 code units, minimal string escaping, ECMAScript
/// number formatting, NaN/Infinity rejected, integers bounded to the
/// IEEE-754 double interchange range. The golden vectors in
/// `Tests/.../Resources/jcs_vectors.json` are the byte-exact contract:
/// this implementation may claim to verify a Morningstar store only
/// while every vector reproduces.

import Foundation

public enum CanonicalizationError: Error, Equatable {
    case nonFiniteNumber
    case integerOutsideDoubleRange(Int64)
}

public enum JCS {
    /// Numbers must fit IEEE-754 double interchange (RFC 8785 / I-JSON).
    public static let maxSafeInteger: Int64 = 9_007_199_254_740_991

    public static func canonicalJSON(_ value: JSONValue) throws -> String {
        var out = ""
        try serialize(value, into: &out)
        return out
    }

    private static func serialize(_ value: JSONValue, into out: inout String) throws {
        switch value {
        case .null:
            out += "null"
        case .bool(let b):
            out += b ? "true" : "false"
        case .int(let n):
            guard abs(n) <= maxSafeInteger else {
                throw CanonicalizationError.integerOutsideDoubleRange(n)
            }
            out += String(n)
        case .double(let d):
            out += try es6NumberString(d)
        case .string(let s):
            out += escapeString(s)
        case .array(let items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                try serialize(item, into: &out)
            }
            out += "]"
        case .object(let object):
            out += "{"
            // RFC 8785 sorts keys by UTF-16 code units — NOT by Unicode
            // code points. They differ when non-BMP keys (surrogate
            // pairs, e.g. emoji) mix with keys in U+E000...U+FFFF.
            let keys = object.keys.sorted { a, b in
                let ua = Array(a.utf16), ub = Array(b.utf16)
                for (x, y) in zip(ua, ub) where x != y { return x < y }
                return ua.count < ub.count
            }
            for (index, key) in keys.enumerated() {
                if index > 0 { out += "," }
                out += escapeString(key)
                out += ":"
                try serialize(object[key]!, into: &out)
            }
            out += "}"
        }
    }

    /// RFC 8785 §3.2.2.2: escape only `"`, `\`, and controls < 0x20;
    /// short forms \b \t \n \f \r; remaining controls as lowercase
    /// \u00xx; everything else (including DEL and all non-ASCII) literal.
    static func escapeString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{09}": out += "\\t"
            case "\u{0A}": out += "\\n"
            case "\u{0C}": out += "\\f"
            case "\u{0D}": out += "\\r"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", Int(scalar.value))
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// ECMAScript `Number::toString` for a finite double (ES2015
    /// §7.1.12.1), mandated by RFC 8785. Same algorithm as the Python
    /// reference: take the platform's shortest round-trip decimal
    /// representation, parse it into significant digits + decimal
    /// exponent, then re-format by the ES6 positional rules. The parse
    /// step makes the algorithm independent of how Swift spells the
    /// shortest form (Swift uses exponent notation earlier than JS).
    static func es6NumberString(_ x: Double) throws -> String {
        guard x.isFinite else { throw CanonicalizationError.nonFiniteNumber }
        if x == 0 { return "0" }  // covers -0.0: ES6 String(-0) is "0"
        let sign = x < 0 ? "-" : ""
        // Swift's Double description is the shortest string that
        // round-trips (Ryū), like Python's repr and ES6's base output.
        let repr = String(abs(x))
        let mantissa: Substring
        var exponent = 0
        if let eIndex = repr.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = repr[..<eIndex]
            exponent = Int(repr[repr.index(after: eIndex)...]) ?? 0
        } else {
            mantissa = repr[...]
        }
        let parts = mantissa.split(separator: ".", maxSplits: 1,
                                   omittingEmptySubsequences: false)
        let intPart = String(parts[0])
        let fracPart = parts.count > 1 ? String(parts[1]) : ""
        let digitsAll = intPart + fracPart
        let stripped = String(digitsAll.drop(while: { $0 == "0" }))
        let leading = digitsAll.count - stripped.count
        var digits = stripped
        while digits.hasSuffix("0") { digits.removeLast() }
        let n = digits.count
        // value = digits × 10^(k−n); k = decimal-point position within
        // the significant digits
        let k = intPart.count - leading + exponent

        let body: String
        if n <= k && k <= 21 {
            body = digits + String(repeating: "0", count: k - n)
        } else if 0 < k && k <= 21 {
            let idx = digits.index(digits.startIndex, offsetBy: k)
            body = digits[..<idx] + "." + digits[idx...]
        } else if -6 < k && k <= 0 {
            body = "0." + String(repeating: "0", count: -k) + digits
        } else {
            let e10 = k - 1
            let first = String(digits.first!)
            let rest = String(digits.dropFirst())
            let mant = n > 1 ? "\(first).\(rest)" : first
            body = "\(mant)e\(e10 >= 0 ? "+" : "-")\(abs(e10))"
        }
        return sign + body
    }
}
