import XCTest
@testable import MorningstarKit

/// The reference implementation's invariant suite, ported to the SQLite
/// store. The trigger tests matter most: they prove append-only is enforced
/// by the database itself, not merely by the absence of an update API.
final class SQLiteStoreTests: XCTestCase {

    var directory: URL!
    var store: SQLiteStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("morningstar-sqlite-\(UUID().uuidString)")
        store = try SQLiteStore(directory: directory)
    }

    override func tearDownWithError() throws {
        store?.close()
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    func commit(_ observation: String = "meeting ended 14:17") throws -> Capture {
        try store.commitCapture(
            observation: observation, phenomenology: "relief", action: "closed laptop")
    }

    /// Opens the maintenance latch, runs `body`, closes it — simulating an
    /// attacker (or a bug) writing straight to the database file.
    func withLatchOpen(_ body: () throws -> Void) throws {
        try store.connection.execute(
            "INSERT OR REPLACE INTO _guard (key, value) VALUES ('maintenance_unlocked','1')")
        defer {
            try? store.connection.execute("DELETE FROM _guard WHERE key='maintenance_unlocked'")
        }
        try body()
    }

    // MARK: - versions

    func testFreshStoreRegistersEveryVersion() throws {
        XCTAssertEqual(try store.protocolVersions().compactMap { $0.string("version") },
                       ["0.1", "0.2", "0.3"])
        XCTAssertEqual(try store.schemaVersions().compactMap { $0.string("schema_version") },
                       ["0.1", "0.2", "0.3"])
        XCTAssertEqual(store.schemaVersion, "0.3")
        let types = try store.events().compactMap { $0.string("event_type") }
        XCTAssertEqual(types.filter { $0 == "protocol_version_registered" }.count, migrations.count)
        XCTAssertEqual(types.filter { $0 == "schema_migrated" }.count, migrations.count)
        XCTAssertTrue(try store.verifyIntegrity().ok)
    }

    // 1. A committed capture cannot be modified.
    func testCommittedCaptureCannotBeModified() throws {
        let capture = try commit()
        XCTAssertThrowsError(try store.connection.execute(
            "UPDATE captures SET observation='rewritten history' WHERE id=?",
            [.text(capture.id)])) { error in
            guard let sqlError = error as? SQLiteError else {
                return XCTFail("expected SQLiteError, got \(error)")
            }
            XCTAssertTrue(sqlError.isAppendOnlyViolation, sqlError.message)
        }
        XCTAssertThrowsError(try store.connection.execute(
            "DELETE FROM captures WHERE id=?", [.text(capture.id)])) { error in
            guard let sqlError = error as? SQLiteError else {
                return XCTFail("expected SQLiteError, got \(error)")
            }
            XCTAssertTrue(sqlError.isAppendOnlyViolation, sqlError.message)
        }
        XCTAssertEqual(try store.capture(id: capture.id).observation, "meeting ended 14:17")
        XCTAssertTrue(try store.verifyIntegrity().ok)
    }

    func testEventsAndAnnotationsAreAlsoAppendOnly() throws {
        let capture = try commit()
        try store.annotate(captureID: capture.id, type: "note", body: "later thought")
        for sql in ["UPDATE events SET event_type='forged' WHERE seq=1",
                    "DELETE FROM events WHERE seq=1",
                    "UPDATE annotations SET body='forged'",
                    "DELETE FROM annotations"] {
            XCTAssertThrowsError(try store.connection.execute(sql), sql)
        }
    }

    // 2. A correction creates an annotation.
    func testCorrectionCreatesAnnotation() throws {
        let capture = try commit()
        let annotation = try store.annotate(
            captureID: capture.id, type: "correction", body: "the meeting ended 14:19")
        XCTAssertEqual(annotation.type, "correction")
        XCTAssertEqual(try store.annotations(for: capture.id).map(\.id), [annotation.id])
        // The original capture is byte-identical.
        let after = try store.capture(id: capture.id)
        XCTAssertEqual(after.observation, capture.observation)
        XCTAssertEqual(after.integrityHash, capture.integrityHash)
        // ...and the correction is on the ledger as its own event.
        XCTAssertTrue(try store.events().contains {
            $0.string("event_type") == "capture_correction_proposed"
        })
        XCTAssertTrue(try store.verifyIntegrity().ok)
    }

    // 3. Interpretations reference captures without altering them.
    func testInterpretationReferencesWithoutAltering() throws {
        let capture = try commit()
        let before = try store.capture(id: capture.id)
        let interpretation = try store.createInterpretation(
            title: "Possible avoidance pattern", body: "Maybe I withdraw when…",
            captureIDs: [capture.id])
        XCTAssertTrue(interpretation.current.referencedCaptureIDs.contains(capture.id))
        XCTAssertEqual(try store.capture(id: capture.id), before)
        XCTAssertTrue(try store.verifyIntegrity().ok)
    }

    // 4. Competing interpretations can coexist.
    func testCompetingInterpretationsCoexist() throws {
        let capture = try commit()
        let a = try store.createInterpretation(
            title: "Reading A", body: "It meant X.", captureIDs: [capture.id])
        let b = try store.createInterpretation(
            title: "Reading B", body: "It meant not-X.", captureIDs: [capture.id])
        let both = try store.interpretations(referencing: capture.id)
        XCTAssertEqual(Set(both.map(\.id)), Set([a.id, b.id]))
        XCTAssertTrue(both.allSatisfy { $0.current.status == "active" })
    }

    func testRevisionBranchAndSupersede() throws {
        let capture = try commit()
        let interpretation = try store.createInterpretation(
            title: "First reading", body: "v1", captureIDs: [capture.id], confidence: 0.4)
        let revised = try store.reviseInterpretation(
            interpretation.id, body: "v2", confidence: 0.6)
        XCTAssertEqual(revised.current.revision, 2)
        XCTAssertEqual(revised.revisions.map(\.body), ["v1", "v2"])

        let branch = try store.createInterpretation(
            title: "Alternative reading", body: "other take",
            captureIDs: [capture.id], parentInterpretationID: interpretation.id)
        XCTAssertEqual(branch.parentInterpretationID, interpretation.id)

        let superseded = try store.setStatus("superseded", forInterpretation: interpretation.id)
        XCTAssertEqual(superseded.current.status, "superseded")
        // History of the superseded interpretation is intact.
        XCTAssertEqual(superseded.revisions.map(\.revision), [1, 2, 3])
        XCTAssertTrue(try store.verifyIntegrity().ok)

        XCTAssertThrowsError(try store.setStatus("nonsense", forInterpretation: interpretation.id))
    }

    // 5. Schema changes require a new version record.
    // 12. Historical captures remain readable after a schema migration.
    func testSchemaChangeRequiresNewVersionRecordAndHistoryStaysReadable() throws {
        let old = try commit("written under schema 0.3")

        XCTAssertThrowsError(try store.apply(Migration(
            id: 4, schemaVersion: "0.3",  // reuses a registered version
            description: "sneaky mutation", migrationNotes: "", compatibilityNotes: "",
            statements: ["ALTER TABLE captures ADD COLUMN sneaky TEXT"]))) { error in
            XCTAssertEqual(error as? SchemaVersionError, .versionAlreadyRegistered("0.3"))
        }
        XCTAssertThrowsError(try store.apply(Migration(
            id: 7, schemaVersion: "0.7", description: "skips ahead",
            migrationNotes: "", compatibilityNotes: "", statements: []))) { error in
            XCTAssertEqual(error as? SchemaVersionError, .notSequential(expected: 4, got: 7))
        }

        try store.apply(Migration(
            id: 4, schemaVersion: "0.3.1", description: "adds an optional column",
            migrationNotes: "additive; old rows keep NULL",
            compatibilityNotes: "captures recorded under 0.3 stay valid",
            statements: ["ALTER TABLE captures ADD COLUMN mood TEXT"]))
        XCTAssertEqual(store.schemaVersion, "0.3.1")
        XCTAssertEqual(try store.schemaVersions().compactMap { $0.string("schema_version") },
                       ["0.1", "0.2", "0.3", "0.3.1"])
        XCTAssertTrue(try store.events().contains {
            $0.string("event_type") == "schema_migrated"
                && $0.string("payload")?.contains("0.3.1") == true
        })

        // The old capture is still readable under its original version...
        let readback = try store.capture(id: old.id)
        XCTAssertEqual(readback.observation, "written under schema 0.3")
        XCTAssertEqual(readback.schemaVersion, "0.3")
        // ...and new captures record the new one.
        let new = try commit("written under schema 0.3.1")
        XCTAssertEqual(new.schemaVersion, "0.3.1")
        let report = try store.verifyIntegrity()
        XCTAssertTrue(report.ok, "\(report.errors)")
    }

    // 7. Hash verification detects tampering.
    func testTamperingIsDetected() throws {
        let capture = try commit("it happened")
        XCTAssertTrue(try store.verifyIntegrity().ok)
        try withLatchOpen {
            try store.connection.execute(
                "UPDATE captures SET observation='it never happened' WHERE id=?",
                [.text(capture.id)])
        }
        let report = try store.verifyIntegrity()
        XCTAssertFalse(report.ok)
        XCTAssertTrue(report.errors.contains { $0.contains("does not match") },
                      "\(report.errors)")
    }

    func testTamperingWithAnEventIsDetected() throws {
        try commit()
        try withLatchOpen {
            try store.connection.execute(
                "UPDATE events SET created_at='1999-01-01T00:00:00.000Z' WHERE seq=1")
        }
        let report = try store.verifyIntegrity()
        XCTAssertFalse(report.ok)
        XCTAssertTrue(report.errors.contains { $0.contains("event 1") }, "\(report.errors)")
    }

    // 8. Optional metadata may be absent.
    func testOptionalMetadataMayBeAbsent() throws {
        let capture = try store.commitCapture(observation: "door closed")
        XCTAssertNil(capture.source)
        XCTAssertNil(capture.recallLatency)
        XCTAssertNil(capture.recordedAt)
        XCTAssertTrue(capture.contextSnapshot.stated.isEmpty)
        XCTAssertTrue(try store.verifyIntegrity().ok)
    }

    func testStatedContextIsFilteredToKnownKeys() throws {
        let capture = try store.commitCapture(
            observation: "walked home",
            statedContext: ["location": "Bernau", "unexpected": "dropped", "weather": ""])
        XCTAssertEqual(capture.contextSnapshot.stated["location"], .string("Bernau"))
        XCTAssertNil(capture.contextSnapshot.stated["unexpected"])  // unknown key dropped
        XCTAssertNil(capture.contextSnapshot.stated["weather"])     // empty value dropped
        XCTAssertTrue(try store.verifyIntegrity().ok)
    }

    // 10. Sequence numbers are assigned automatically.
    func testSequenceNumbersAssignedAutomaticallyAndChained() throws {
        let a = try commit("one"), b = try commit("two"), c = try commit("three")
        XCTAssertEqual([a.sequenceNumber, b.sequenceNumber, c.sequenceNumber], [1, 2, 3])
        XCTAssertEqual(b.previousHash, a.integrityHash)
        XCTAssertEqual(c.previousHash, b.integrityHash)
        XCTAssertEqual(a.previousHash, genesisHash)
        XCTAssertTrue(try store.verifyIntegrity().ok)
    }

    func testAutomaticContextRecordsElapsedAndNoDeviceDataWithoutConsent() throws {
        try commit("first")
        let second = try commit("second")
        let automatic = second.contextSnapshot.automatic
        XCTAssertNotEqual(automatic["elapsed_since_previous_capture_seconds"], .null)
        XCTAssertEqual(automatic["device_id"], .string(store.deviceID))
        XCTAssertNil(automatic["platform"])
        XCTAssertNil(automatic["hostname"])

        try store.setDeviceMetadataConsent(true)
        let third = try commit("third")
        XCTAssertNotNil(third.contextSnapshot.automatic["platform"])
        XCTAssertTrue(try store.verifyIntegrity().ok)
    }

    // MARK: - hide vs redact

    func testHideKeepsEvidenceAndIsReversible() throws {
        let capture = try commit("sensitive but retained")
        try store.hide(captureID: capture.id)
        XCTAssertEqual(try store.captures().count, 0)
        XCTAssertEqual(try store.captures(includeHidden: true).count, 1)
        XCTAssertTrue(try store.capture(id: capture.id).hidden)
        // Evidence intact: content unchanged and still verifying.
        XCTAssertEqual(try store.capture(id: capture.id).observation, "sensitive but retained")
        var report = try store.verifyIntegrity()
        XCTAssertTrue(report.ok, "\(report.errors)")
        XCTAssertTrue(report.warnings.contains { $0.contains("hidden") }, "\(report.warnings)")

        try store.unhide(captureID: capture.id)
        XCTAssertEqual(try store.captures().count, 1)
        report = try store.verifyIntegrity()
        XCTAssertTrue(report.ok)
        XCTAssertFalse(report.warnings.contains { $0.contains("hidden") })
    }

    func testRedactionBlanksContentButPreservesTheChain() throws {
        let first = try commit("kept")
        let capture = try commit("sensitive content")
        try store.annotate(captureID: capture.id, type: "note", body: "also sensitive")

        try store.redact(captureID: capture.id)

        let after = try store.capture(id: capture.id)
        XCTAssertTrue(after.redacted)
        XCTAssertEqual(after.observation, redactedPlaceholder)
        XCTAssertEqual(try store.annotations(for: capture.id).first?.body, redactedPlaceholder)
        // Content is gone from the ledger too.
        let ledger = try store.events().compactMap { $0.string("payload") }.joined()
        XCTAssertFalse(ledger.contains("sensitive content"))
        XCTAssertFalse(ledger.contains("also sensitive"))
        // The earlier capture is untouched and the deletion is itself an event.
        XCTAssertEqual(try store.capture(id: first.id).observation, "kept")
        XCTAssertTrue(try store.events().contains { $0.string("event_type") == "capture_redacted" })
        // Redaction is a warning, not tampering.
        let report = try store.verifyIntegrity()
        XCTAssertTrue(report.ok, "\(report.errors)")
        XCTAssertTrue(report.warnings.contains { $0.contains("redacted") }, "\(report.warnings)")
    }

    // MARK: - persistence

    func testReopeningTheStoreKeepsEverythingVerifiable() throws {
        let capture = try commit("persisted")
        try store.annotate(captureID: capture.id, type: "note", body: "later thought")
        try store.createInterpretation(
            title: "A reading", body: "perhaps…", captureIDs: [capture.id], confidence: 0.4)
        store.close()

        store = try SQLiteStore(directory: directory)
        XCTAssertEqual(try store.captures().count, 1)
        XCTAssertEqual(try store.captures().first?.integrityHash, capture.integrityHash)
        XCTAssertEqual(try store.annotations(for: capture.id).count, 1)
        XCTAssertEqual(try store.interpretations().count, 1)
        XCTAssertEqual(try store.interpretations().first?.current.confidence, 0.4)
        // Reopening must not re-run migrations or re-register versions.
        XCTAssertEqual(try store.schemaVersions().count, migrations.count)
        XCTAssertEqual(try store.protocolVersions().count, migrations.count)
        let report = try store.verifyIntegrity()
        XCTAssertTrue(report.ok, "\(report.errors)")
    }

    // 11 / 9. The operator never supplies ids, and leakage never blocks.
    func testCaptureNeedsOnlyTextAndLeakageNeverBlocks() throws {
        let text = "he was trying to hurt me because he is a narcissist"
        XCTAssertFalse(checkLeakage(observation: text, phenomenology: "", action: "").isEmpty)
        let capture = try store.commitCapture(observation: text)
        XCTAssertEqual(try store.capture(id: capture.id).observation, text)
        XCTAssertFalse(capture.id.isEmpty)          // id assigned by the store
        XCTAssertEqual(capture.sequenceNumber, 1)   // sequence assigned by the store
        XCTAssertTrue(try store.verifyIntegrity().ok)
    }

    func testMissingReferencesAreReported() throws {
        let capture = try commit()
        try store.annotate(captureID: capture.id, type: "note", body: "x")
        // Point the annotation at a capture that does not exist. Foreign keys
        // are switched off for the write so this simulates a corrupted file
        // rather than something the store's own API could produce.
        try store.connection.execute("PRAGMA foreign_keys = OFF")
        try withLatchOpen {
            try store.connection.execute(
                "UPDATE annotations SET capture_id='00000000-0000-4000-8000-000000000000'")
        }
        try store.connection.execute("PRAGMA foreign_keys = ON")
        let report = try store.verifyIntegrity()
        XCTAssertFalse(report.ok)
        XCTAssertTrue(report.errors.contains { $0.contains("references missing capture") },
                      "\(report.errors)")
    }
}
