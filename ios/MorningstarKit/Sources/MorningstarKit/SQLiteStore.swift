/// Append-only SQLite storage — parity with `morningstar/morningstar/store.py`.
///
/// The event ledger (`events`) is the provenance backbone: every write
/// appends an event carrying the object content, chained by previous-hash.
/// Captures, annotations, and interpretations are also materialized in their
/// own tables for querying, but nothing evidential is ever updated in place:
/// SQLite triggers (see `Migrations.swift`) reject UPDATE/DELETE on those
/// tables, so even hand-written SQL against the file fails.
///
/// The single sanctioned mutation is redaction (permanent deletion). It
/// blanks content in place, marks rows `redacted`, and appends a
/// `capture_redacted` event. Redacted rows keep their original integrity
/// hash so the chain stays continuous; the integrity checker reports them as
/// redacted rather than tampered. This is the documented trade-off between
/// deletion and append-only provenance.

import Foundation

public final class SQLiteStore {
    public let directory: URL
    public let databaseURL: URL
    /// Exposed for inspection and for tests that must attempt raw writes to
    /// prove the triggers reject them.
    public let connection: SQLiteConnection

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        self.directory = directory
        self.databaseURL = directory.appendingPathComponent("morningstar.db")
        self.connection = try SQLiteConnection(path: databaseURL.path)
        try migrate()
        try ensureDeviceID()
    }

    public func close() { connection.close() }

    // MARK: - migrations & versions

    private func appliedMigrations() throws -> [Row] {
        let exists = try connection.query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='schema_migrations'")
        guard !exists.isEmpty else { return [] }
        return try connection.query("SELECT * FROM schema_migrations ORDER BY id")
    }

    private func migrate() throws {
        let applied = Set(try appliedMigrations().compactMap { $0.int("id") })
        for migration in migrations where !applied.contains(Int64(migration.id)) {
            try apply(migration)
        }
    }

    /// Applies a schema migration. Refuses to mutate the schema without a
    /// strictly sequential id and an unused schema version.
    public func apply(_ migration: Migration) throws {
        let applied = try appliedMigrations()
        let lastID = Int(applied.last?.int("id") ?? 0)
        guard migration.id == lastID + 1 else {
            throw SchemaVersionError.notSequential(expected: lastID + 1, got: migration.id)
        }
        guard !applied.contains(where: { $0.string("schema_version") == migration.schemaVersion })
        else {
            throw SchemaVersionError.versionAlreadyRegistered(migration.schemaVersion)
        }
        try connection.transaction {
            for statement in migration.statements {
                try connection.execute(statement)
            }
            try connection.execute(
                """
                INSERT INTO schema_migrations
                (id, schema_version, applied_at, description, migration_notes, compatibility_notes)
                VALUES (?,?,?,?,?,?)
                """,
                [SQLValue(migration.id), .text(migration.schemaVersion),
                 .text(Timestamp.now()), .text(migration.description),
                 .text(migration.migrationNotes), .text(migration.compatibilityNotes)])
            if let record = migration.protocolRecord {
                try register(record, schemaVersion: migration.schemaVersion)
            }
            try appendEvent("schema_migrated", payload: .object([
                "migration_id": .int(Int64(migration.id)),
                "schema_version": .string(migration.schemaVersion),
                "description": .string(migration.description),
                "migration_notes": .string(migration.migrationNotes),
                "compatibility_notes": .string(migration.compatibilityNotes),
            ]), schemaVersion: migration.schemaVersion)
        }
    }

    private func register(_ record: ProtocolRecord, schemaVersion: String) throws {
        try connection.execute(
            "INSERT INTO protocol_versions VALUES (?,?,?,?,?,?)",
            [.text(UUID().uuidString.lowercased()), .text(record.version),
             .text(Timestamp.now()), .text(record.changeDescription),
             .text(record.migrationNotes), .text(record.compatibilityNotes)])
        try appendEvent("protocol_version_registered", payload: .object([
            "version": .string(record.version),
            "change_description": .string(record.changeDescription),
            "migration_notes": .string(record.migrationNotes),
            "compatibility_notes": .string(record.compatibilityNotes),
        ]), schemaVersion: schemaVersion)
    }

    public var schemaVersion: String {
        do {
            if let row = try connection.queryOne(
                "SELECT schema_version FROM schema_migrations ORDER BY id DESC LIMIT 1"),
               let version = row.string("schema_version") {
                return version
            }
        } catch {
            // Fall through to the compiled-in version.
        }
        return Morningstar.schemaVersion
    }

    public func schemaVersions() throws -> [Row] {
        try connection.query("SELECT * FROM schema_migrations ORDER BY id")
    }

    public func protocolVersions() throws -> [Row] {
        try connection.query("SELECT * FROM protocol_versions ORDER BY created_at")
    }

    // MARK: - settings & device identity

    public func setting(_ key: String) throws -> String? {
        try connection.queryOne("SELECT value FROM settings WHERE key=?", [.text(key)])?
            .string("value")
    }

    public func setSetting(_ key: String, _ value: String) throws {
        try connection.execute(
            """
            INSERT INTO settings (key, value) VALUES (?,?)
            ON CONFLICT(key) DO UPDATE SET value=excluded.value
            """,
            [.text(key), .text(value)])
    }

    private func ensureDeviceID() throws {
        // A random identifier for this data directory: it identifies the
        // runtime without revealing anything about the device.
        if try setting("device_id") == nil {
            try setSetting("device_id", UUID().uuidString.lowercased()
                .replacingOccurrences(of: "-", with: ""))
        }
    }

    public var deviceID: String {
        ((try? setting("device_id")) ?? nil) ?? "unknown"
    }

    public var deviceMetadataConsent: Bool {
        (((try? setting("device_metadata_consent")) ?? nil) ?? "") == "true"
    }

    public func setDeviceMetadataConsent(_ granted: Bool) throws {
        try setSetting("device_metadata_consent", granted ? "true" : "false")
        try connection.transaction {
            try appendEvent("device_metadata_consent_changed",
                            payload: .object(["granted": .bool(granted)]))
        }
    }

    // MARK: - event ledger

    /// Appends one event. Callers wrap this in a transaction.
    @discardableResult
    private func appendEvent(_ type: String, payload: JSONValue,
                             schemaVersion explicitSchema: String? = nil) throws -> InstrumentEvent {
        let last = try connection.queryOne(
            "SELECT seq, integrity_hash FROM events ORDER BY seq DESC LIMIT 1")
        let seq = Int((last?.int("seq") ?? 0) + 1)
        let previousHash = last?.string("integrity_hash") ?? genesisHash
        let schema = explicitSchema ?? schemaVersion
        let createdAt = Timestamp.now()
        let id = UUID().uuidString.lowercased()
        let content = InstrumentEvent(
            id: id, seq: seq, eventType: type, createdAt: createdAt, payload: payload,
            protocolVersion: Morningstar.protocolVersion, schemaVersion: schema,
            previousHash: previousHash, integrityHash: "")
        let digest = try integrityHash(content.hashContent)
        try connection.execute(
            """
            INSERT INTO events
            (seq, id, event_type, created_at, payload, protocol_version, schema_version,
             integrity_hash, previous_hash)
            VALUES (?,?,?,?,?,?,?,?,?)
            """,
            [SQLValue(seq), .text(id), .text(type), .text(createdAt),
             .text(try JCS.canonicalJSON(payload)),
             .text(Morningstar.protocolVersion), .text(schema),
             .text(digest), .text(previousHash)])
        return InstrumentEvent(
            id: id, seq: seq, eventType: type, createdAt: createdAt, payload: payload,
            protocolVersion: Morningstar.protocolVersion, schemaVersion: schema,
            previousHash: previousHash, integrityHash: digest)
    }

    public func events() throws -> [Row] {
        try connection.query("SELECT * FROM events ORDER BY seq")
    }

    public func recentEvents(_ limit: Int = 20) throws -> [Row] {
        try connection.query("SELECT * FROM events ORDER BY seq DESC LIMIT ?", [SQLValue(limit)])
    }

    // MARK: - captures

    /// Context the instrument collects on its own. Everything here is
    /// measured or configured — never inferred.
    public func automaticContext(captureSource: String) throws -> [String: JSONValue] {
        let zone = TimeZone.current
        var context: [String: JSONValue] = [
            "captured_at_utc": .string(Timestamp.now()),
            "timezone": .string(zone.identifier),
            "utc_offset_minutes": .int(Int64(zone.secondsFromGMT() / 60)),
            "app_version": .string(Morningstar.appVersion),
            "protocol_version": .string(Morningstar.protocolVersion),
            "schema_version": .string(schemaVersion),
            "device_id": .string(deviceID),
            "capture_source": .string(captureSource),
        ]
        let last = try connection.queryOne(
            "SELECT created_at FROM captures ORDER BY sequence_number DESC LIMIT 1")
        if let createdAt = last?.string("created_at"), let date = Timestamp.date(createdAt) {
            context["elapsed_since_previous_capture_seconds"] =
                .int(Int64(Date().timeIntervalSince(date)))
        } else {
            context["elapsed_since_previous_capture_seconds"] = .null
        }
        if deviceMetadataConsent {
            context["platform"] = .string(ProcessInfo.processInfo.operatingSystemVersionString)
            context["hostname"] = .string(ProcessInfo.processInfo.hostName)
        }
        return context
    }

    /// Creates and commits a capture in one step; it is immutable from this
    /// moment and later material becomes annotations. The caller supplies
    /// natural text only — ids, sequence numbers, hashes, timestamps, and
    /// versions are assigned here.
    /// Commits a capture at event speed: one blurt of text, recorded as
    /// `unsorted` rather than pushed into a channel it may not belong in.
    ///
    /// Nothing here asserts the capture is immediate — only that it came
    /// through the fast path, which is the factual part. `recall_latency`
    /// stays unstated rather than being filled in with a guess.
    @discardableResult
    public func commitQuickCapture(
        _ text: String, captureSource: String = "quick"
    ) throws -> Capture {
        try commitCapture(unsorted: text, captureSource: captureSource)
    }

    @discardableResult
    public func commitCapture(
        observation: String = "", phenomenology: String = "", action: String = "",
        recordedAt: String? = nil, source: String? = nil, recallLatency: String? = nil,
        statedContext: [String: String] = [:], captureSource: String = "api",
        unsorted: String? = nil
    ) throws -> Capture {
        try connection.transaction {
            let last = try connection.queryOne(
                "SELECT sequence_number, integrity_hash FROM captures "
                + "ORDER BY sequence_number DESC LIMIT 1")
            let sequenceNumber = Int((last?.int("sequence_number") ?? 0) + 1)
            let previousHash = last?.string("integrity_hash") ?? genesisHash
            let now = Timestamp.now()
            let zone = TimeZone.current
            var stated: [String: JSONValue] = [:]
            for key in statedContextKeys {
                if let value = statedContext[key], !value.isEmpty {
                    stated[key] = .string(value)
                }
            }
            let snapshot = ContextSnapshot(
                automatic: try automaticContext(captureSource: captureSource), stated: stated)
            let id = UUID().uuidString.lowercased()
            let content = Capture.hashContent(
                id: id, sequenceNumber: sequenceNumber, createdAt: now,
                recordedAt: nilIfBlank(recordedAt), timezone: zone.identifier,
                observation: observation, phenomenology: phenomenology, action: action,
                source: nilIfBlank(source), recallLatency: nilIfBlank(recallLatency),
                protocolVersion: Morningstar.protocolVersion, schemaVersion: schemaVersion,
                contextSnapshot: snapshot, previousHash: previousHash, committedAt: now,
                unsorted: nilIfBlank(unsorted))
            let digest = try integrityHash(content)

            try connection.execute(
                """
                INSERT INTO captures
                (id, sequence_number, created_at, recorded_at, timezone, observation,
                 phenomenology, action, source, recall_latency, protocol_version,
                 schema_version, context_snapshot, integrity_hash, previous_hash,
                 committed_at, unsorted)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """,
                [.text(id), SQLValue(sequenceNumber), .text(now),
                 SQLValue(nilIfBlank(recordedAt)), .text(zone.identifier),
                 .text(observation), .text(phenomenology), .text(action),
                 SQLValue(nilIfBlank(source)), SQLValue(nilIfBlank(recallLatency)),
                 .text(Morningstar.protocolVersion), .text(schemaVersion),
                 .text(try JCS.canonicalJSON(snapshot.jsonValue)),
                 .text(digest), .text(previousHash), .text(now),
                 SQLValue(nilIfBlank(unsorted))])
            try connection.execute(
                "INSERT INTO capture_visibility (capture_id, hidden, updated_at) VALUES (?,0,?)",
                [.text(id), .text(now)])

            var payload = content
            if case .object(var fields) = payload {
                fields["integrity_hash"] = .string(digest)
                payload = .object(fields)
            }
            try appendEvent("capture_committed", payload: payload)

            return Capture(
                id: id, sequenceNumber: sequenceNumber, createdAt: now,
                recordedAt: nilIfBlank(recordedAt), timezone: zone.identifier,
                observation: observation, phenomenology: phenomenology, action: action,
                source: nilIfBlank(source), recallLatency: nilIfBlank(recallLatency),
                protocolVersion: Morningstar.protocolVersion, schemaVersion: schemaVersion,
                contextSnapshot: snapshot, previousHash: previousHash, committedAt: now,
                integrityHash: digest, unsorted: nilIfBlank(unsorted))
        }
    }

    public func capture(id: String) throws -> Capture {
        guard let row = try connection.queryOne("SELECT * FROM captures WHERE id=?", [.text(id)])
        else { throw StoreError.notFound("capture \(id)") }
        return try decodeCapture(row)
    }

    public func captures(includeHidden: Bool = false) throws -> [Capture] {
        let rows = try connection.query("SELECT * FROM captures ORDER BY sequence_number")
        let all = try rows.map(decodeCapture)
        return includeHidden ? all : all.filter { !$0.hidden }
    }

    // MARK: - visibility & redaction

    public func hide(captureID: String) throws { try setHidden(captureID, true) }
    public func unhide(captureID: String) throws { try setHidden(captureID, false) }

    private func setHidden(_ captureID: String, _ hidden: Bool) throws {
        _ = try capture(id: captureID)
        try connection.transaction {
            try connection.execute(
                """
                INSERT INTO capture_visibility (capture_id, hidden, updated_at) VALUES (?,?,?)
                ON CONFLICT(capture_id) DO UPDATE SET
                    hidden=excluded.hidden, updated_at=excluded.updated_at
                """,
                [.text(captureID), SQLValue(hidden), .text(Timestamp.now())])
            try appendEvent(hidden ? "capture_hidden" : "capture_unhidden",
                            payload: .object(["capture_id": .string(captureID)]))
        }
    }

    /// Permanent deletion of capture content.
    ///
    /// Content is blanked in the capture row, its annotations, and the event
    /// payloads that carried it. The rows, ordering, original integrity
    /// hashes, and hash chain remain, so the ledger stays continuous but the
    /// redacted content is reported as unverifiable by the integrity check.
    /// This is irreversible.
    public func redact(captureID: String) throws {
        _ = try capture(id: captureID)
        // Event rows carrying this capture's content, found without relying
        // on the JSON1 extension.
        var affectedEventSeqs: [Int64] = []
        for row in try events() {
            guard let seq = row.int("seq"), let payloadText = row.string("payload"),
                  let payload = try? JSONValue.parse(payloadText) else { continue }
            if payload["id"]?.stringValue == captureID
                || payload["capture_id"]?.stringValue == captureID {
                affectedEventSeqs.append(seq)
            }
        }
        try connection.transaction {
            // The latch is only open inside this transaction; if anything
            // throws, the rollback removes it along with the writes.
            try connection.execute(
                "INSERT OR REPLACE INTO _guard (key, value) VALUES ('maintenance_unlocked','1')")
            try connection.execute(
                """
                UPDATE captures SET observation=?, phenomenology=?, action=?,
                    source=NULL, recall_latency=NULL, recorded_at=NULL,
                    unsorted=NULL,                    context_snapshot=?, redacted=1 WHERE id=?
                """,
                [.text(redactedPlaceholder), .text(redactedPlaceholder),
                 .text(redactedPlaceholder),
                 .text(try JCS.canonicalJSON(.object(["redacted": .bool(true)]))),
                 .text(captureID)])
            try connection.execute(
                "UPDATE annotations SET body=?, redacted=1 WHERE capture_id=?",
                [.text(redactedPlaceholder), .text(captureID)])
            let blanked = try JCS.canonicalJSON(.object([
                "redacted": .bool(true), "capture_id": .string(captureID),
            ]))
            for seq in affectedEventSeqs {
                try connection.execute(
                    "UPDATE events SET payload=?, redacted=1 WHERE seq=?",
                    [.text(blanked), .int(seq)])
            }
            try connection.execute("DELETE FROM _guard WHERE key='maintenance_unlocked'")
            try appendEvent("capture_redacted",
                            payload: .object(["capture_id": .string(captureID)]))
        }
    }

    // MARK: - annotations

    /// Attaches later material to a committed capture. This is the only way
    /// to "correct" a capture — the original is untouched.
    @discardableResult
    public func annotate(captureID: String, type: String, body: String) throws -> Annotation {
        _ = try capture(id: captureID)
        let kind = annotationTypes.contains(type) ? type : "note"
        return try connection.transaction {
            let id = UUID().uuidString.lowercased()
            let createdAt = Timestamp.now()
            let annotation = Annotation(
                id: id, captureID: captureID, createdAt: createdAt, type: kind, body: body,
                protocolVersion: Morningstar.protocolVersion, integrityHash: "")
            let digest = try integrityHash(annotation.hashContent)
            try connection.execute(
                """
                INSERT INTO annotations
                (id, capture_id, created_at, type, body, integrity_hash, protocol_version)
                VALUES (?,?,?,?,?,?,?)
                """,
                [.text(id), .text(captureID), .text(createdAt), .text(kind), .text(body),
                 .text(digest), .text(Morningstar.protocolVersion)])
            var payload = annotation.hashContent
            if case .object(var fields) = payload {
                fields["integrity_hash"] = .string(digest)
                payload = .object(fields)
            }
            try appendEvent(
                kind == "correction" ? "capture_correction_proposed" : "annotation_added",
                payload: payload)
            return Annotation(
                id: id, captureID: captureID, createdAt: createdAt, type: kind, body: body,
                protocolVersion: Morningstar.protocolVersion, integrityHash: digest)
        }
    }

    /// Records how the operator would separate an unsorted capture into the
    /// three channels — as an annotation, never as an edit.
    ///
    /// Deciding after the fact which part of a blurt was observation and which
    /// was already interpretation is later knowledge *about* the evidence. It
    /// is kept beside the original, which stays exactly as it was taken down.
    @discardableResult
    public func sortLater(
        captureID: String, observation: String = "",
        phenomenology: String = "", action: String = ""
    ) throws -> Annotation {
        let capture = try capture(id: captureID)
        guard capture.unsorted != nil else {
            throw StoreError.invalidStatus("capture \(captureID) has no unsorted text to sort")
        }
        let body = try JCS.canonicalJSON(.object([
            "sorted_observation": .string(observation),
            "sorted_phenomenology": .string(phenomenology),
            "sorted_action": .string(action),
        ]))
        return try annotate(captureID: captureID, type: "context", body: body)
    }

    public func annotations(for captureID: String) throws -> [Annotation] {
        try connection.query(
            "SELECT * FROM annotations WHERE capture_id=? ORDER BY created_at",
            [.text(captureID)]
        ).compactMap(decodeAnnotation)
    }

    // MARK: - interpretations

    @discardableResult
    public func createInterpretation(
        title: String, body: String, captureIDs: [String],
        parentInterpretationID: String? = nil, confidence: Double? = nil
    ) throws -> Interpretation {
        for captureID in captureIDs { _ = try capture(id: captureID) }
        if let parent = parentInterpretationID { _ = try interpretation(id: parent) }
        let id = try connection.transaction { () -> String in
            let id = UUID().uuidString.lowercased()
            let createdAt = Timestamp.now()
            let base = Interpretation(
                id: id, createdAt: createdAt, parentInterpretationID: parentInterpretationID,
                protocolVersion: Morningstar.protocolVersion, integrityHash: "", revisions: [])
            let digest = try integrityHash(base.hashContent)
            try connection.execute(
                """
                INSERT INTO interpretations
                (id, created_at, parent_interpretation_id, integrity_hash, protocol_version)
                VALUES (?,?,?,?,?)
                """,
                [.text(id), .text(createdAt), SQLValue(parentInterpretationID),
                 .text(digest), .text(Morningstar.protocolVersion)])
            let revision = try addRevision(
                interpretationID: id, revision: 1, title: title, body: body,
                captureIDs: captureIDs, status: "active", confidence: confidence)
            var payload = base.hashContent
            if case .object(var fields) = payload {
                fields["integrity_hash"] = .string(digest)
                fields["revision"] = revision.hashContent
                payload = .object(fields)
            }
            try appendEvent("interpretation_created", payload: payload)
            return id
        }
        return try interpretation(id: id)
    }

    /// Appends a new revision; earlier revisions remain on record.
    @discardableResult
    public func reviseInterpretation(
        _ id: String, title: String? = nil, body: String? = nil,
        captureIDs: [String]? = nil, status: String? = nil, confidence: Double? = nil
    ) throws -> Interpretation {
        let existing = try interpretation(id: id)
        if let captureIDs { for captureID in captureIDs { _ = try capture(id: captureID) } }
        let current = existing.current
        try connection.transaction {
            let revision = try addRevision(
                interpretationID: id, revision: current.revision + 1,
                title: title ?? current.title, body: body ?? current.body,
                captureIDs: captureIDs ?? current.referencedCaptureIDs,
                status: status ?? current.status,
                confidence: confidence ?? current.confidence)
            let statusOnly = status != nil && title == nil && body == nil
            try appendEvent(
                statusOnly ? "interpretation_status_changed" : "interpretation_revised",
                payload: revision.hashContent)
        }
        return try interpretation(id: id)
    }

    @discardableResult
    public func setStatus(_ status: String, forInterpretation id: String) throws -> Interpretation {
        guard interpretationStatuses.contains(status) else {
            throw StoreError.invalidStatus(status)
        }
        return try reviseInterpretation(id, status: status)
    }

    private func addRevision(interpretationID: String, revision: Int, title: String,
                             body: String, captureIDs: [String], status: String,
                             confidence: Double?) throws -> InterpretationRevision {
        guard interpretationStatuses.contains(status) else {
            throw StoreError.invalidStatus(status)
        }
        let id = UUID().uuidString.lowercased()
        let createdAt = Timestamp.now()
        let draft = InterpretationRevision(
            id: id, interpretationID: interpretationID, revision: revision,
            createdAt: createdAt, title: title, body: body,
            referencedCaptureIDs: captureIDs, status: status, confidence: confidence,
            protocolVersion: Morningstar.protocolVersion, integrityHash: "")
        let digest = try integrityHash(draft.hashContent)
        try connection.execute(
            """
            INSERT INTO interpretation_revisions
            (id, interpretation_id, revision, created_at, title, body,
             referenced_capture_ids, status, confidence, integrity_hash, protocol_version)
            VALUES (?,?,?,?,?,?,?,?,?,?,?)
            """,
            [.text(id), .text(interpretationID), SQLValue(revision), .text(createdAt),
             .text(title), .text(body),
             .text(try JCS.canonicalJSON(.array(captureIDs.map { .string($0) }))),
             .text(status), SQLValue(confidence), .text(digest),
             .text(Morningstar.protocolVersion)])
        return InterpretationRevision(
            id: id, interpretationID: interpretationID, revision: revision,
            createdAt: createdAt, title: title, body: body,
            referencedCaptureIDs: captureIDs, status: status, confidence: confidence,
            protocolVersion: Morningstar.protocolVersion, integrityHash: digest)
    }

    public func interpretation(id: String) throws -> Interpretation {
        guard let row = try connection.queryOne(
            "SELECT * FROM interpretations WHERE id=?", [.text(id)])
        else { throw StoreError.notFound("interpretation \(id)") }
        let revisions = try connection.query(
            "SELECT * FROM interpretation_revisions WHERE interpretation_id=? ORDER BY revision",
            [.text(id)]
        ).compactMap(decodeRevision)
        guard !revisions.isEmpty else {
            throw StoreError.corruptLedger("interpretation \(id) has no revisions")
        }
        return Interpretation(
            id: id, createdAt: row.string("created_at") ?? "",
            parentInterpretationID: row.string("parent_interpretation_id"),
            protocolVersion: row.string("protocol_version") ?? Morningstar.protocolVersion,
            integrityHash: row.string("integrity_hash") ?? "", revisions: revisions)
    }

    public func interpretations() throws -> [Interpretation] {
        try connection.query("SELECT id FROM interpretations ORDER BY created_at")
            .compactMap { $0.string("id") }
            .compactMap { try? interpretation(id: $0) }
    }

    public func interpretations(referencing captureID: String) throws -> [Interpretation] {
        try interpretations().filter { $0.current.referencedCaptureIDs.contains(captureID) }
    }

    // MARK: - integrity verification

    /// Rechecks the whole store: event ordering, hash-chain continuity,
    /// object hashes, reference integrity, and version registration.
    /// Redactions, hidden captures, and protocol 0.1-era objects are
    /// reported as warnings — instrument conditions, not user failures.
    public func verifyIntegrity() throws -> IntegrityReport {
        var report = IntegrityReport()
        report.checkedAt = Timestamp.now()

        let schemaSet = Set(try schemaVersions().compactMap { $0.string("schema_version") })
        let protocolSet = Set(try protocolVersions().compactMap { $0.string("version") })
        report.schemaVersionCount = schemaSet.count
        report.protocolVersionCount = protocolSet.count

        var previous = genesisHash
        var expectedSeq: Int64 = 1
        for row in try events() {
            report.eventCount += 1
            let seq = row.int("seq") ?? expectedSeq
            let type = row.string("event_type") ?? "?"
            let label = "event \(seq) (\(type))"
            guard let stored = row.string("integrity_hash"),
                  let previousHash = row.string("previous_hash") else {
                report.errors.append("\(label): row is missing hash columns")
                expectedSeq += 1
                continue
            }
            if seq != expectedSeq {
                report.errors.append("\(label): sequence gap (expected \(expectedSeq))")
                expectedSeq = seq
            }
            if previousHash != previous {
                report.errors.append("\(label): previous-hash break in event chain")
            }
            if row.bool("redacted") {
                report.warnings.append("\(label): payload redacted; content hash not verifiable")
            } else {
                switch hashEra(forProtocol: row.string("protocol_version")) {
                case .legacyUnverifiable:
                    report.warnings.append(
                        "\(label): protocol 0.1 era — verify with the reference implementation")
                case .jcs:
                    let payload = (try? JSONValue.parse(row.string("payload") ?? "null")) ?? .null
                    let content = InstrumentEvent(
                        id: row.string("id") ?? "", seq: Int(seq), eventType: type,
                        createdAt: row.string("created_at") ?? "", payload: payload,
                        protocolVersion: row.string("protocol_version") ?? "",
                        schemaVersion: row.string("schema_version") ?? "",
                        previousHash: previousHash, integrityHash: "")
                    if (try? integrityHash(content.hashContent)) != stored {
                        report.errors.append("\(label): stored hash does not match content")
                    }
                }
            }
            previous = stored
            expectedSeq += 1
        }

        var previousCaptureHash = genesisHash
        var captureIDs = Set<String>()
        for row in try connection.query("SELECT * FROM captures ORDER BY sequence_number") {
            report.captureCount += 1
            let sequence = row.int("sequence_number") ?? 0
            let label = "capture \(String(format: "%03d", sequence))"
            if let id = row.string("id") { captureIDs.insert(id) }
            guard let stored = row.string("integrity_hash"),
                  let previousHash = row.string("previous_hash") else {
                report.errors.append("\(label): row is missing hash columns")
                continue
            }
            if previousHash != previousCaptureHash {
                report.errors.append("\(label): previous-hash break in capture chain")
            }
            previousCaptureHash = stored
            if let schema = row.string("schema_version"), !schemaSet.contains(schema) {
                report.errors.append("\(label): unregistered schema version \(schema)")
            }
            if let proto = row.string("protocol_version"), !protocolSet.contains(proto) {
                report.errors.append("\(label): unregistered protocol version \(proto)")
            }
            if row.bool("redacted") {
                report.warnings.append(
                    "\(label): content redacted; original hash retained but no longer verifiable")
                continue
            }
            switch hashEra(forProtocol: row.string("protocol_version")) {
            case .legacyUnverifiable:
                report.warnings.append(
                    "\(label): protocol 0.1 era — verify with the reference implementation")
            case .jcs:
                let capture = try decodeCapture(row)
                if (try? integrityHash(capture.hashContent)) != stored {
                    report.errors.append(
                        "\(label): stored hash does not match content "
                        + "(possible retrospective edit)")
                }
            }
        }

        for row in try connection.query("SELECT * FROM annotations") {
            report.annotationCount += 1
            let id = row.string("id") ?? "?"
            let label = "annotation \(String(id.prefix(8)))"
            if let captureID = row.string("capture_id"), !captureIDs.contains(captureID) {
                report.errors.append("\(label): references missing capture")
            }
            if row.bool("redacted") { continue }
            guard let stored = row.string("integrity_hash") else { continue }
            switch hashEra(forProtocol: row.string("protocol_version")) {
            case .legacyUnverifiable:
                report.warnings.append(
                    "\(label): protocol 0.1 era — verify with the reference implementation")
            case .jcs:
                if let annotation = decodeAnnotation(row),
                   (try? integrityHash(annotation.hashContent)) != stored {
                    report.errors.append("\(label): stored hash does not match content")
                }
            }
        }

        for interpretation in try interpretations() {
            report.interpretationCount += 1
            let label = "interpretation \(String(interpretation.id.prefix(8)))"
            for revision in interpretation.revisions {
                if (try? integrityHash(revision.hashContent)) != revision.integrityHash {
                    report.errors.append(
                        "\(label) rev \(revision.revision): stored hash does not match content")
                }
                for captureID in revision.referencedCaptureIDs where !captureIDs.contains(captureID) {
                    report.errors.append(
                        "\(label) rev \(revision.revision): references missing capture")
                }
            }
        }

        let hidden = try connection.queryOne(
            "SELECT COUNT(*) AS count FROM capture_visibility WHERE hidden=1")?.int("count") ?? 0
        if hidden > 0 {
            report.warnings.append(
                "\(hidden) capture(s) hidden from normal view (evidence retained)")
        }
        return report
    }

    // MARK: - row decoding

    private func decodeCapture(_ row: Row) throws -> Capture {
        guard let id = row.string("id") else {
            throw StoreError.corruptLedger("capture row without id")
        }
        var snapshot = ContextSnapshot()
        if let text = row.string("context_snapshot"),
           let parsed = try? JSONValue.parse(text) {
            if case .object(let automatic)? = parsed["automatic"] { snapshot.automatic = automatic }
            if case .object(let stated)? = parsed["stated"] { snapshot.stated = stated }
        }
        let hiddenRow = try connection.queryOne(
            "SELECT hidden FROM capture_visibility WHERE capture_id=?", [.text(id)])
        return Capture(
            id: id, sequenceNumber: Int(row.int("sequence_number") ?? 0),
            createdAt: row.string("created_at") ?? "", recordedAt: row.string("recorded_at"),
            timezone: row.string("timezone") ?? "", observation: row.string("observation") ?? "",
            phenomenology: row.string("phenomenology") ?? "", action: row.string("action") ?? "",
            source: row.string("source"), recallLatency: row.string("recall_latency"),
            protocolVersion: row.string("protocol_version") ?? "",
            schemaVersion: row.string("schema_version") ?? "",
            contextSnapshot: snapshot, previousHash: row.string("previous_hash") ?? "",
            committedAt: row.string("committed_at") ?? "",
            integrityHash: row.string("integrity_hash") ?? "",
            unsorted: row.string("unsorted"),
            redacted: row.bool("redacted"), hidden: hiddenRow?.bool("hidden") ?? false)
    }

    private func decodeAnnotation(_ row: Row) -> Annotation? {
        guard let id = row.string("id"), let captureID = row.string("capture_id"),
              let createdAt = row.string("created_at"), let type = row.string("type"),
              let body = row.string("body"), let digest = row.string("integrity_hash")
        else { return nil }
        return Annotation(
            id: id, captureID: captureID, createdAt: createdAt, type: type, body: body,
            protocolVersion: row.string("protocol_version") ?? Morningstar.protocolVersion,
            integrityHash: digest)
    }

    private func decodeRevision(_ row: Row) -> InterpretationRevision? {
        guard let id = row.string("id"),
              let interpretationID = row.string("interpretation_id"),
              let revision = row.int("revision"), let createdAt = row.string("created_at"),
              let title = row.string("title"), let body = row.string("body"),
              let status = row.string("status"), let digest = row.string("integrity_hash"),
              let refsText = row.string("referenced_capture_ids"),
              let refs = try? JSONValue.parse(refsText), case .array(let items) = refs
        else { return nil }
        return InterpretationRevision(
            id: id, interpretationID: interpretationID, revision: Int(revision),
            createdAt: createdAt, title: title, body: body,
            referencedCaptureIDs: items.compactMap { $0.stringValue },
            status: status, confidence: row.double("confidence"),
            protocolVersion: row.string("protocol_version") ?? Morningstar.protocolVersion,
            integrityHash: digest)
    }
}

private func nilIfBlank(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
}
