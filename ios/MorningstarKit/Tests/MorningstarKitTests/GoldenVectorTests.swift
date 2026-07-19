import XCTest
@testable import MorningstarKit

/// The portable contract: this Swift implementation may claim to verify a
/// Morningstar store only while every RFC 8785 golden vector reproduces
/// byte-for-byte. The fixture is a byte-copy of
/// `morningstar/tests/golden/jcs_vectors.json` (CI diffs the two so they
/// cannot drift).
///
/// The fixture is parsed with the package's own `JSONValue.parse` rather
/// than Foundation's JSONDecoder, so the int/double distinction is
/// deterministic (Foundation is ambiguous about `1` vs `1.0`) — and the
/// parser gets exercised in the process.
final class GoldenVectorTests: XCTestCase {

    func loadFixtureRoot() throws -> JSONValue {
        guard let url = Bundle.module.url(
            forResource: "jcs_vectors", withExtension: "json") else {
            throw XCTSkip("golden fixture not bundled")
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try JSONValue.parse(text)
    }

    func testProtocolVersion() throws {
        let root = try loadFixtureRoot()
        XCTAssertEqual(root["protocol_version"]?.stringValue, "0.2")
    }

    func testEveryVectorReproducesCanonicalBytesAndHash() throws {
        let root = try loadFixtureRoot()
        guard case .array(let vectors)? = root["vectors"] else {
            return XCTFail("fixture has no vectors array")
        }
        XCTAssertFalse(vectors.isEmpty)
        for vector in vectors {
            let name = vector["name"]?.stringValue ?? "?"
            guard let value = vector["value"],
                  let expectedCanonical = vector["canonical"]?.stringValue,
                  let expectedHash = vector["sha256"]?.stringValue else {
                XCTFail("vector \(name) missing fields"); continue
            }
            let canonical = try JCS.canonicalJSON(value)
            XCTAssertEqual(canonical, expectedCanonical,
                           "canonical bytes differ for vector \(name)")
            let hash = try integrityHash(value)
            XCTAssertEqual(hash, expectedHash,
                           "sha256 differs for vector \(name)")
        }
    }
}
