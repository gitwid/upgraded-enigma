import XCTest
@testable import MorningstarKit

final class CanonicalTests: XCTestCase {

    /// Known ECMAScript String(Number) outputs — verifiable in any JS
    /// engine, and the same set the Python reference cross-checks.
    func testES6NumberFormatting() throws {
        let cases: [(Double, String)] = [
            (0.0, "0"), (-0.0, "0"), (1.0, "1"), (0.5, "0.5"), (4.50, "4.5"),
            (2e-3, "0.002"), (1e21, "1e+21"), (1e20, "100000000000000000000"),
            (1e-6, "0.000001"), (1e-7, "1e-7"),
            (3.141592653589793, "3.141592653589793"),
            (333333333.33333329, "333333333.3333333"),
            (1.5e21, "1.5e+21"), (5e-324, "5e-324"),
            (1.7976931348623157e308, "1.7976931348623157e+308"),
            (-42.75, "-42.75"),
        ]
        for (value, expected) in cases {
            XCTAssertEqual(try JCS.es6NumberString(value), expected, "\(value)")
        }
    }

    func testNaNInfinityAndUnsafeIntegersRejected() {
        XCTAssertThrowsError(try JCS.canonicalJSON(.double(.nan)))
        XCTAssertThrowsError(try JCS.canonicalJSON(.double(.infinity)))
        XCTAssertThrowsError(try JCS.canonicalJSON(.double(-.infinity)))
        XCTAssertThrowsError(try JCS.canonicalJSON(.int(JCS.maxSafeInteger + 1)))
        XCTAssertNoThrow(try JCS.canonicalJSON(.int(JCS.maxSafeInteger)))
    }

    /// U+FF01 < U+1F600 by code point, but the emoji's UTF-16 high
    /// surrogate (0xD83D) < 0xFF01 — JCS requires the emoji key first.
    func testUTF16KeyOrdering() throws {
        let out = try JCS.canonicalJSON(.object(["！": .int(1), "\u{1F600}": .int(2)]))
        let emojiIdx = out.range(of: "\u{1F600}")!.lowerBound
        let bangIdx = out.range(of: "！")!.lowerBound
        XCTAssertLessThan(emojiIdx, bangIdx)
    }

    func testControlCharacterEscaping() throws {
        let out = try JCS.canonicalJSON(.string("\u{00}\u{1f}\u{7f}\u{08}\t\n\u{0c}\r\"\\"))
        // DEL (0x7f) stays literal; low controls use short forms or \u00xx.
        XCTAssertEqual(out, "\"\\u0000\\u001f\u{7f}\\b\\t\\n\\f\\r\\\"\\\\\"")
    }

    func testIntegerValuedDoubleMatchesInteger() throws {
        // Both render "1" in JCS — the int/double distinction is invisible
        // for integer values, which is why hashes stay stable.
        XCTAssertEqual(try JCS.canonicalJSON(.double(1.0)),
                       try JCS.canonicalJSON(.int(1)))
    }

    func testParserRoundTripsCanonicalForms() throws {
        // Already-canonical (keys sorted): parse then canonicalize = identity.
        let samples = [
            #"{"a":1,"b":2}"#,
            #"{"arr":[null,true,false,{},[]]}"#,
            #"{"s":"émotions ✓ — fin de partie"}"#,
        ]
        for s in samples {
            let value = try JSONValue.parse(s)
            XCTAssertEqual(try JCS.canonicalJSON(value), s)
        }
    }

    func testParserSortsKeysOnCanonicalization() throws {
        let value = try JSONValue.parse(#"{"b":2,"a":1,"A":0}"#)
        XCTAssertEqual(try JCS.canonicalJSON(value), #"{"A":0,"a":1,"b":2}"#)
    }
}
