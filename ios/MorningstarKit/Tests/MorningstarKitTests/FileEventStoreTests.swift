import XCTest
@testable import MorningstarKit

/// Mirrors the invariant tests of the Python reference store, adapted to
/// the interim file-backed ledger: automatic sequence numbers, capture
/// immutability via annotations, interpretations that don't touch
/// captures, coexisting interpretations, hash-chain verification, and
/// tamper detection on the ledger file.
final class FileEventStoreTests: XCTestCase {

    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("morningstar-test-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func makeStore() throws -> FileEventStore {
        try FileEventStore(directory: directory)
    }

    func testGenesisEventAndCleanVerify() throws {
        let store = try makeStore()
        let report = try store.verifyIntegrity()
        XCTAssertTrue(report.ok, "\(report.errors)")
        XCTAssertGreaterThanOrEqual(report.eventCount, 1) // protocol registration
    }

    func testSequenceNumbersAssignedAutomatically() throws {
        let store = try makeStore()
        let a = try store.commitCapture(observation: "one", phenomenology: "", action: "")
        let b = try store.commitCapture(observation: "two", phenomenology: "", action: "")
        let c = try store.commitCapture(observation: "three", phenomenology: "", action: "")
        XCTAssertEqual([a.sequenceNumber, b.sequenceNumber, c.sequenceNumber], [1, 2, 3])
        // captures are chained
        XCTAssertEqual(b.previousHash, a.integrityHash)
        XCTAssertEqual(c.previousHash, b.integrityHash)
        XCTAssertTrue(try store.verifyIntegrity().ok)
    }

    func testCorrectionCreatesAnnotationLeavingCaptureUnchanged() throws {
        let store = try makeStore()
        let cap = try store.commitCapture(
            observation: "meeting ended 14:17", phenomenology: "relief", action: "closed laptop")
        let ann = try store.annotate(
            captureID: cap.id, type: "correction", body: "actually 14:19")
        XCTAssertEqual(ann.type, "correction")
        let after = try store.capture(id: cap.id)
        XCTAssertEqual(after.observation, "meeting ended 14:17")
        XCTAssertEqual(after.integrityHash, cap.integrityHash)
        XCTAssertEqual(store.annotations(for: cap.id).map(\.id), [ann.id])
    }

    func testInterpretationsReferenceWithoutAlteringAndCoexist() throws {
        let store = try makeStore()
        let cap = try store.commitCapture(observation: "door closed", phenomenology: "", action: "")
        let before = try store.capture(id: cap.id)
        let a = try store.createInterpretation(
            title: "Reading A", body: "meant X", captureIDs: [cap.id])
        let b = try store.createInterpretation(
            title: "Reading B", body: "meant not-X", captureIDs: [cap.id])
        XCTAssertEqual(try store.capture(id: cap.id), before)  // unchanged
        XCTAssertEqual(a.current.status, "active")
        XCTAssertEqual(b.current.status, "active")
        XCTAssertTrue(a.current.referencedCaptureIDs.contains(cap.id))
        XCTAssertNotEqual(a.id, b.id)  // competing interpretations coexist
        XCTAssertTrue(try store.verifyIntegrity().ok)
    }

    func testInterpretationRevisionAppendsHistory() throws {
        let store = try makeStore()
        let cap = try store.commitCapture(observation: "x", phenomenology: "", action: "")
        let interp = try store.createInterpretation(
            title: "First", body: "v1", captureIDs: [cap.id], confidence: 0.4)
        let revised = try store.reviseInterpretation(interp.id, body: "v2", confidence: 0.6)
        XCTAssertEqual(revised.current.revision, 2)
        XCTAssertEqual(revised.revisions.map(\.body), ["v1", "v2"])
        XCTAssertTrue(try store.verifyIntegrity().ok)
    }

    func testOptionalMetadataMayBeAbsent() throws {
        let store = try makeStore()
        let cap = try store.commitCapture(observation: "door closed", phenomenology: "", action: "")
        XCTAssertNil(cap.source)
        XCTAssertNil(cap.recallLatency)
        XCTAssertNil(cap.recordedAt)
        XCTAssertTrue(cap.contextSnapshot.stated.isEmpty)
    }

    func testPersistenceReloadsAndStillVerifies() throws {
        let firstHash: String
        do {
            let store = try makeStore()
            let cap = try store.commitCapture(
                observation: "persisted", phenomenology: "calm", action: "saved")
            try store.annotate(captureID: cap.id, type: "note", body: "later thought")
            firstHash = cap.integrityHash
        }
        // A fresh store over the same directory replays the ledger.
        let reopened = try makeStore()
        XCTAssertEqual(reopened.captures.count, 1)
        XCTAssertEqual(reopened.captures.first?.integrityHash, firstHash)
        XCTAssertEqual(reopened.annotations.count, 1)
        XCTAssertTrue(try reopened.verifyIntegrity().ok)
    }

    func testTamperingWithLedgerIsDetected() throws {
        let store = try makeStore()
        try store.commitCapture(
            observation: "it happened", phenomenology: "", action: "")
        XCTAssertTrue(try store.verifyIntegrity().ok)
        // Rewrite the observation directly in the ledger file, as an
        // attacker with file access could.
        var text = try String(contentsOf: store.ledgerURL, encoding: .utf8)
        text = text.replacingOccurrences(of: "it happened", with: "it never happened")
        try text.write(to: store.ledgerURL, atomically: true, encoding: .utf8)
        let report = try store.verifyIntegrity()
        XCTAssertFalse(report.ok)
        XCTAssertTrue(report.errors.contains { $0.contains("does not match") })
    }

    func testLeakageWarnsButNeverBlocks() throws {
        let store = try makeStore()
        let text = "he was trying to hurt me because he is a narcissist"
        let warnings = checkLeakage(observation: text, phenomenology: "", action: "")
        XCTAssertFalse(warnings.isEmpty)                 // plenty to flag
        let cap = try store.commitCapture(observation: text, phenomenology: "", action: "")
        XCTAssertEqual(try store.capture(id: cap.id).observation, text)  // committed unchanged
    }

    func testPhenomenologyFeltStatesNotPoliced() {
        XCTAssertTrue(checkLeakage(
            channel: .phenomenology,
            text: "feeling rejected. depressed. chest pressure.").isEmpty)
    }
}
