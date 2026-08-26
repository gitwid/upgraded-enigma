import XCTest
@testable import MorningstarKit

/// Protocol 0.3: capture at event speed.
///
/// The load-bearing test here is `testCapturesWrittenUnderOlderProtocolStillVerify`:
/// adding a field to hashed content is exactly the change that silently
/// invalidates history if content is rebuilt from the *current* version rather
/// than each object's own.
final class QuickCaptureTests: XCTestCase {

    var directory: URL!
    var store: SQLiteStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("morningstar-quick-\(UUID().uuidString)")
        store = try SQLiteStore(directory: directory)
    }

    override func tearDownWithError() throws {
        store?.close()
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testProtocolAndSchemaAreRegisteredThroughOhThree() throws {
        XCTAssertEqual(try store.schemaVersions().compactMap { $0.string("schema_version") },
                       ["0.1", "0.2", "0.3"])
        XCTAssertEqual(try store.protocolVersions().compactMap { $0.string("version") },
                       ["0.1", "0.2", "0.3"])
        XCTAssertEqual(store.schemaVersion, "0.3")
        XCTAssertTrue(try store.verifyIntegrity().ok)
    }

    func testQuickCaptureRecordsTextUnsortedAndVerifies() throws {
        let capture = try store.commitQuickCapture("she said the thing again and my chest went tight")
        XCTAssertEqual(capture.unsorted, "she said the thing again and my chest went tight")
        // The blurt is not silently filed into a channel it may not belong in.
        XCTAssertEqual(capture.observation, "")
        XCTAssertEqual(capture.phenomenology, "")
        XCTAssertEqual(capture.action, "")
        // Immediacy is not asserted; only the path taken is recorded.
        XCTAssertNil(capture.recallLatency)
        XCTAssertEqual(capture.contextSnapshot.automatic["capture_source"], .string("quick"))
        XCTAssertEqual(capture.protocolVersion, "0.3")

        let report = try store.verifyIntegrity()
        XCTAssertTrue(report.ok, "\(report.errors)")
        XCTAssertEqual(try store.capture(id: capture.id).unsorted, capture.unsorted)
    }

    func testUnsortedJoinsHashedContentOnlyFromProtocolOhThree() throws {
        let base: (String) -> JSONValue = { version in
            Capture.hashContent(
                id: "fixed-id", sequenceNumber: 1, createdAt: "T", recordedAt: nil,
                timezone: "UTC", observation: "o", phenomenology: "p", action: "a",
                source: nil, recallLatency: nil, protocolVersion: version,
                schemaVersion: version, contextSnapshot: ContextSnapshot(),
                previousHash: genesisHash, committedAt: "T", unsorted: "blurt")
        }
        guard case .object(let older) = base("0.2"), case .object(let newer) = base("0.3") else {
            return XCTFail("expected objects")
        }
        XCTAssertNil(older["unsorted"])                       // absent before 0.3
        XCTAssertEqual(newer["unsorted"], .string("blurt"))   // present from 0.3
    }

    /// A capture committed under protocol 0.2 must keep verifying after the
    /// store has moved to 0.3 — its hash was computed over a field set that no
    /// longer matches the current one.
    func testCapturesWrittenUnderOlderProtocolStillVerify() throws {
        // Build a store stopped at schema 0.2, the way a store written by the
        // previous release would look.
        let legacyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("morningstar-legacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: legacyDirectory) }

        let legacy = try SQLiteStore(directory: legacyDirectory)
        // Simulate the 0.2-era row: content hashed without `unsorted`.
        let now = Timestamp.now()
        let content = Capture.hashContent(
            id: "legacy-capture", sequenceNumber: 1, createdAt: now, recordedAt: nil,
            timezone: "UTC", observation: "door closed", phenomenology: "", action: "",
            source: nil, recallLatency: nil, protocolVersion: "0.2",
            schemaVersion: "0.2", contextSnapshot: ContextSnapshot(),
            previousHash: genesisHash, committedAt: now)
        let digest = try integrityHash(content)
        try legacy.connection.execute(
            """
            INSERT INTO captures
            (id, sequence_number, created_at, recorded_at, timezone, observation,
             phenomenology, action, source, recall_latency, protocol_version,
             schema_version, context_snapshot, integrity_hash, previous_hash, committed_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            [.text("legacy-capture"), SQLValue(1), .text(now), .null, .text("UTC"),
             .text("door closed"), .text(""), .text(""), .null, .null,
             .text("0.2"), .text("0.2"),
             .text(try JCS.canonicalJSON(ContextSnapshot().jsonValue)),
             .text(digest), .text(genesisHash), .text(now)])

        let report = try legacy.verifyIntegrity()
        XCTAssertTrue(report.ok,
                      "a protocol 0.2 capture must still verify under 0.3: \(report.errors)")

        // And a 0.3 capture in the same store verifies alongside it.
        try legacy.commitQuickCapture("written after the bump")
        let mixed = try legacy.verifyIntegrity()
        XCTAssertTrue(mixed.ok, "\(mixed.errors)")
        XCTAssertEqual(mixed.captureCount, 2)
    }

    func testSortingLaterAnnotatesAndLeavesTheCaptureUntouched() throws {
        let capture = try store.commitQuickCapture("he slammed the door, I froze, said nothing")
        let before = try store.capture(id: capture.id)

        let annotation = try store.sortLater(
            captureID: capture.id,
            observation: "the door closed loudly",
            phenomenology: "I froze",
            action: "said nothing")

        XCTAssertEqual(annotation.type, "context")
        XCTAssertTrue(annotation.body.contains("sorted_observation"))
        // The original is byte-identical — sorting is later knowledge, not an edit.
        XCTAssertEqual(try store.capture(id: capture.id), before)
        XCTAssertEqual(try store.capture(id: capture.id).integrityHash, capture.integrityHash)
        XCTAssertTrue(try store.verifyIntegrity().ok)
    }

    func testSortingRequiresAnUnsortedCapture() throws {
        let ordinary = try store.commitCapture(observation: "already sorted")
        XCTAssertThrowsError(try store.sortLater(captureID: ordinary.id, observation: "x"))
    }

    func testQuickCaptureNeverBlocksOnLeakage() throws {
        // The fast path does not run leakage checks at all: at event speed
        // there is no review step to show them in, and nothing may stand
        // between a person and recording what just happened.
        let text = "he did it because he is a narcissist and will never change"
        XCTAssertFalse(checkLeakage(channel: .observation, text: text).isEmpty)
        let capture = try store.commitQuickCapture(text)
        XCTAssertEqual(capture.unsorted, text)
        XCTAssertTrue(try store.verifyIntegrity().ok)
    }

    func testRedactionAlsoClearsTheUnsortedChannel() throws {
        let capture = try store.commitQuickCapture("sensitive blurt")
        try store.redact(captureID: capture.id)
        let after = try store.capture(id: capture.id)
        XCTAssertTrue(after.redacted)
        XCTAssertNil(after.unsorted)
        let ledger = try store.events().compactMap { $0.string("payload") }.joined()
        XCTAssertFalse(ledger.contains("sensitive blurt"))
        let report = try store.verifyIntegrity()
        XCTAssertTrue(report.ok, "\(report.errors)")
    }

    func testQuickAndJourneyCapturesShareOneChain() throws {
        let a = try store.commitQuickCapture("first, fast")
        let b = try store.commitCapture(observation: "second, considered")
        XCTAssertEqual(b.previousHash, a.integrityHash)
        XCTAssertEqual([a.sequenceNumber, b.sequenceNumber], [1, 2])
        XCTAssertTrue(try store.verifyIntegrity().ok)
    }
}
