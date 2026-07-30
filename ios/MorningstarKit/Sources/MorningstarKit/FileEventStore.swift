/// v0 storage: an append-only, hash-chained event log (one canonical
/// JSON event per line). The ledger file is the evidence; captures,
/// annotations, and interpretations are materialized in memory on load.
///
/// This is the interim store for the iOS shell — the SQLite/GRDB port
/// (with database-level immutability triggers, hide/redact, and the
/// full audit surface) is the next milestone and lands on desktop.
/// The primary invariant holds here exactly as in the reference
/// implementation: nothing in the file is ever rewritten; every write
/// appends an event; `verifyIntegrity()` re-derives everything.

import Foundation

public enum StoreError: Error, Equatable {
    case notFound(String)
    case corruptLedger(String)
}

public struct IntegrityReport: Equatable, Sendable {
    public var ok: Bool { errors.isEmpty }
    public var errors: [String] = []
    public var warnings: [String] = []
    public var eventCount = 0
    public var captureCount = 0
    public var annotationCount = 0
    public var interpretationCount = 0
}

public final class FileEventStore {
    public let ledgerURL: URL
    public private(set) var captures: [Capture] = []
    public private(set) var annotations: [Annotation] = []
    public private(set) var interpretations: [String: Interpretation] = [:]
    private var lastEvent: (seq: Int, hash: String)?
    private var lastCapture: (sequenceNumber: Int, hash: String, createdAt: Date)?
    public private(set) var deviceID: String

    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        self.ledgerURL = directory.appendingPathComponent("ledger.jsonl")
        let idURL = directory.appendingPathComponent("device_id")
        if let existing = try? String(contentsOf: idURL, encoding: .utf8) {
            self.deviceID = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            self.deviceID = UUID().uuidString.lowercased()
                .replacingOccurrences(of: "-", with: "")
            try deviceID.write(to: idURL, atomically: true, encoding: .utf8)
        }
        try load()
        if lastEvent == nil {
            try registerGenesis()
        }
    }

    private func now() -> String { iso.string(from: Date()) }

    // MARK: - ledger primitives

    @discardableResult
    private func appendEvent(type: String, payload: JSONValue) throws -> InstrumentEvent {
        let seq = (lastEvent?.seq ?? 0) + 1
        let previous = lastEvent?.hash ?? genesisHash
        let content = InstrumentEvent(
            id: UUID().uuidString.lowercased(), seq: seq, eventType: type,
            createdAt: now(), payload: payload,
            protocolVersion: Morningstar.protocolVersion,
            schemaVersion: Morningstar.schemaVersion,
            previousHash: previous, integrityHash: "")
        let digest = try integrityHash(content.hashContent)
        let event = InstrumentEvent(
            id: content.id, seq: seq, eventType: type, createdAt: content.createdAt,
            payload: payload, protocolVersion: content.protocolVersion,
            schemaVersion: content.schemaVersion, previousHash: previous,
            integrityHash: digest)
        var line = try JCS.canonicalJSON(eventJSON(event))
        line += "\n"
        if FileManager.default.fileExists(atPath: ledgerURL.path) {
            let handle = try FileHandle(forWritingTo: ledgerURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } else {
            try line.write(to: ledgerURL, atomically: true, encoding: .utf8)
        }
        lastEvent = (seq, digest)
        return event
    }

    private func eventJSON(_ e: InstrumentEvent) -> JSONValue {
        .object([
            "id": .string(e.id), "seq": .int(Int64(e.seq)),
            "event_type": .string(e.eventType),
            "created_at": .string(e.createdAt), "payload": e.payload,
            "protocol_version": .string(e.protocolVersion),
            "schema_version": .string(e.schemaVersion),
            "previous_hash": .string(e.previousHash),
            "integrity_hash": .string(e.integrityHash),
        ])
    }

    private func registerGenesis() throws {
        try appendEvent(type: "protocol_version_registered", payload: .object([
            "version": .string(Morningstar.protocolVersion),
            "change_description": .string(
                "Morningstar iOS ledger opened under protocol 0.2 "
                + "(RFC 8785 canonicalization)."),
            "migration_notes": .string("Fresh ledger; nothing to migrate."),
            "compatibility_notes": .string(
                "Interoperable with the Python reference implementation's "
                + "protocol 0.2 hashing; golden vectors are the contract."),
        ]))
    }

    // MARK: - captures

    @discardableResult
    public func commitCapture(
        observation: String, phenomenology: String, action: String,
        recordedAt: String? = nil, source: String? = nil,
        recallLatency: String? = nil, statedContext: [String: String] = [:],
        captureSource: String = "ios-app"
    ) throws -> Capture {
        let createdAt = now()
        let sequenceNumber = (lastCapture?.sequenceNumber ?? 0) + 1
        let previousHash = lastCapture?.hash ?? genesisHash
        let tz = TimeZone.current

        var automatic: [String: JSONValue] = [
            "captured_at_utc": .string(createdAt),
            "timezone": .string(tz.identifier),
            "utc_offset_minutes": .int(Int64(tz.secondsFromGMT() / 60)),
            "app_version": .string(Morningstar.appVersion),
            "protocol_version": .string(Morningstar.protocolVersion),
            "schema_version": .string(Morningstar.schemaVersion),
            "device_id": .string(deviceID),
            "capture_source": .string(captureSource),
        ]
        if let last = lastCapture {
            automatic["elapsed_since_previous_capture_seconds"] =
                .int(Int64(Date().timeIntervalSince(last.createdAt)))
        } else {
            automatic["elapsed_since_previous_capture_seconds"] = .null
        }
        let stated = statedContext.filter { !$0.value.isEmpty }
            .mapValues { JSONValue.string($0) }
        let snapshot = ContextSnapshot(automatic: automatic, stated: stated)

        let id = UUID().uuidString.lowercased()
        let content = Capture.hashContent(
            id: id, sequenceNumber: sequenceNumber, createdAt: createdAt,
            recordedAt: nilIfEmpty(recordedAt), timezone: tz.identifier,
            observation: observation, phenomenology: phenomenology, action: action,
            source: nilIfEmpty(source), recallLatency: nilIfEmpty(recallLatency),
            protocolVersion: Morningstar.protocolVersion,
            schemaVersion: Morningstar.schemaVersion,
            contextSnapshot: snapshot, previousHash: previousHash,
            committedAt: createdAt)
        let digest = try integrityHash(content)
        let capture = Capture(
            id: id, sequenceNumber: sequenceNumber, createdAt: createdAt,
            recordedAt: nilIfEmpty(recordedAt), timezone: tz.identifier,
            observation: observation, phenomenology: phenomenology, action: action,
            source: nilIfEmpty(source), recallLatency: nilIfEmpty(recallLatency),
            protocolVersion: Morningstar.protocolVersion,
            schemaVersion: Morningstar.schemaVersion,
            contextSnapshot: snapshot, previousHash: previousHash,
            committedAt: createdAt, integrityHash: digest)

        var payload = content
        if case .object(var o) = payload {
            o["integrity_hash"] = .string(digest)
            payload = .object(o)
        }
        try appendEvent(type: "capture_committed", payload: payload)
        captures.append(capture)
        lastCapture = (sequenceNumber, digest, Date())
        return capture
    }

    public func capture(id: String) throws -> Capture {
        guard let c = captures.first(where: { $0.id == id }) else {
            throw StoreError.notFound("no capture \(id)")
        }
        return c
    }

    // MARK: - annotations

    @discardableResult
    public func annotate(captureID: String, type: String, body: String) throws -> Annotation {
        _ = try capture(id: captureID)
        let kind = ["note", "correction", "context"].contains(type) ? type : "note"
        let annotation = Annotation(
            id: UUID().uuidString.lowercased(), captureID: captureID,
            createdAt: now(), type: kind, body: body,
            protocolVersion: Morningstar.protocolVersion, integrityHash: "")
        let digest = try integrityHash(annotation.hashContent)
        let final = Annotation(
            id: annotation.id, captureID: captureID, createdAt: annotation.createdAt,
            type: kind, body: body,
            protocolVersion: Morningstar.protocolVersion, integrityHash: digest)
        var payload = final.hashContent
        if case .object(var o) = payload {
            o["integrity_hash"] = .string(digest)
            payload = .object(o)
        }
        try appendEvent(
            type: kind == "correction" ? "capture_correction_proposed" : "annotation_added",
            payload: payload)
        annotations.append(final)
        return final
    }

    public func annotations(for captureID: String) -> [Annotation] {
        annotations.filter { $0.captureID == captureID }
    }

    // MARK: - interpretations

    @discardableResult
    public func createInterpretation(
        title: String, body: String, captureIDs: [String],
        parentInterpretationID: String? = nil, confidence: Double? = nil
    ) throws -> Interpretation {
        for cid in captureIDs { _ = try capture(id: cid) }
        if let parent = parentInterpretationID, interpretations[parent] == nil {
            throw StoreError.notFound("no interpretation \(parent)")
        }
        let baseID = UUID().uuidString.lowercased()
        var interp = Interpretation(
            id: baseID, createdAt: now(),
            parentInterpretationID: parentInterpretationID,
            protocolVersion: Morningstar.protocolVersion,
            integrityHash: "", revisions: [])
        let baseDigest = try integrityHash(interp.hashContent)
        interp = Interpretation(
            id: baseID, createdAt: interp.createdAt,
            parentInterpretationID: parentInterpretationID,
            protocolVersion: Morningstar.protocolVersion,
            integrityHash: baseDigest, revisions: [])
        let revision = try makeRevision(
            interpretationID: baseID, revision: 1, title: title, body: body,
            captureIDs: captureIDs, status: "active", confidence: confidence)
        interp.revisions = [revision]
        var payload = interp.hashContent
        if case .object(var o) = payload {
            o["integrity_hash"] = .string(baseDigest)
            o["revision"] = revision.hashContent
            payload = .object(o)
        }
        try appendEvent(type: "interpretation_created", payload: payload)
        interpretations[baseID] = interp
        return interp
    }

    @discardableResult
    public func reviseInterpretation(
        _ id: String, title: String? = nil, body: String? = nil,
        captureIDs: [String]? = nil, status: String? = nil,
        confidence: Double? = nil
    ) throws -> Interpretation {
        guard var interp = interpretations[id] else {
            throw StoreError.notFound("no interpretation \(id)")
        }
        let current = interp.current
        let revision = try makeRevision(
            interpretationID: id, revision: current.revision + 1,
            title: title ?? current.title, body: body ?? current.body,
            captureIDs: captureIDs ?? current.referencedCaptureIDs,
            status: status ?? current.status,
            confidence: confidence ?? current.confidence)
        interp.revisions.append(revision)
        try appendEvent(
            type: (status != nil && title == nil && body == nil)
                ? "interpretation_status_changed" : "interpretation_revised",
            payload: revision.hashContent)
        interpretations[id] = interp
        return interp
    }

    private func makeRevision(
        interpretationID: String, revision: Int, title: String, body: String,
        captureIDs: [String], status: String, confidence: Double?
    ) throws -> InterpretationRevision {
        var rev = InterpretationRevision(
            id: UUID().uuidString.lowercased(), interpretationID: interpretationID,
            revision: revision, createdAt: now(), title: title, body: body,
            referencedCaptureIDs: captureIDs, status: status,
            confidence: confidence,
            protocolVersion: Morningstar.protocolVersion, integrityHash: "")
        let digest = try integrityHash(rev.hashContent)
        rev = InterpretationRevision(
            id: rev.id, interpretationID: interpretationID, revision: revision,
            createdAt: rev.createdAt, title: title, body: body,
            referencedCaptureIDs: captureIDs, status: status,
            confidence: confidence,
            protocolVersion: Morningstar.protocolVersion, integrityHash: digest)
        return rev
    }

    // MARK: - load & verify

    private func load() throws {
        captures = []
        annotations = []
        interpretations = [:]
        lastEvent = nil
        lastCapture = nil
        guard let data = try? Data(contentsOf: ledgerURL),
              let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let value = try JSONValue.parse(String(line))
            guard case .object = value,
                  case .int(let seq)? = value["seq"],
                  let type = value["event_type"]?.stringValue,
                  let hash = value["integrity_hash"]?.stringValue else {
                throw StoreError.corruptLedger("unreadable event line")
            }
            lastEvent = (Int(seq), hash)
            try materialize(type: type, event: value)
        }
    }

    private func materialize(type: String, event: JSONValue) throws {
        guard let payload = event["payload"] else { return }
        switch type {
        case "capture_committed":
            guard let capture = captureFromPayload(payload) else {
                throw StoreError.corruptLedger("bad capture payload")
            }
            captures.append(capture)
            lastCapture = (capture.sequenceNumber, capture.integrityHash,
                           iso.date(from: capture.createdAt) ?? Date())
        case "annotation_added", "capture_correction_proposed":
            if let a = annotationFromPayload(payload) { annotations.append(a) }
        case "interpretation_created":
            if let i = interpretationFromPayload(payload) { interpretations[i.id] = i }
        case "interpretation_revised", "interpretation_status_changed":
            if let rev = revisionFromPayload(payload),
               var interp = interpretations[rev.interpretationID] {
                interp.revisions.append(rev)
                interpretations[rev.interpretationID] = interp
            }
        default:
            break
        }
    }

    public func verifyIntegrity() throws -> IntegrityReport {
        var report = IntegrityReport()
        guard let data = try? Data(contentsOf: ledgerURL),
              let text = String(data: data, encoding: .utf8) else {
            report.warnings.append("ledger file missing or empty")
            return report
        }
        var previous = genesisHash
        var expectedSeq = 1
        var captureIDs = Set<String>()
        var previousCaptureHash = genesisHash
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let value = try? JSONValue.parse(String(line)),
                  case .int(let seq)? = value["seq"],
                  let type = value["event_type"]?.stringValue,
                  let stored = value["integrity_hash"]?.stringValue,
                  let prev = value["previous_hash"]?.stringValue else {
                report.errors.append("event \(expectedSeq): unreadable line")
                expectedSeq += 1
                continue
            }
            report.eventCount += 1
            let label = "event \(seq) (\(type))"
            if Int(seq) != expectedSeq {
                report.errors.append("\(label): sequence gap (expected \(expectedSeq))")
                expectedSeq = Int(seq)
            }
            if prev != previous {
                report.errors.append("\(label): previous-hash break in event chain")
            }
            let protocolVersion = value["protocol_version"]?.stringValue
            switch hashEra(forProtocol: protocolVersion) {
            case .jcs:
                var content = value
                if case .object(var o) = content {
                    o.removeValue(forKey: "integrity_hash")
                    content = .object(o)
                }
                if let recomputed = try? integrityHash(content), recomputed != stored {
                    report.errors.append("\(label): stored hash does not match content")
                }
            case .legacyUnverifiable:
                report.warnings.append(
                    "\(label): protocol 0.1 era — verify with the reference implementation")
            }
            if type == "capture_committed", let payload = value["payload"] {
                report.captureCount += 1
                if let cid = payload["id"]?.stringValue { captureIDs.insert(cid) }
                if let capPrev = payload["previous_hash"]?.stringValue {
                    if capPrev != previousCaptureHash {
                        report.errors.append("\(label): previous-hash break in capture chain")
                    }
                }
                if let capHash = payload["integrity_hash"]?.stringValue {
                    previousCaptureHash = capHash
                    var content = payload
                    if case .object(var o) = content {
                        o.removeValue(forKey: "integrity_hash")
                        content = .object(o)
                    }
                    if let recomputed = try? integrityHash(content), recomputed != capHash {
                        report.errors.append(
                            "\(label): capture hash does not match content "
                            + "(possible retrospective edit)")
                    }
                }
            }
            if type == "annotation_added" || type == "capture_correction_proposed" {
                report.annotationCount += 1
                if let ref = value["payload"]?["capture_id"]?.stringValue,
                   !captureIDs.contains(ref) {
                    report.errors.append("\(label): references missing capture")
                }
            }
            if type == "interpretation_created" { report.interpretationCount += 1 }
            previous = stored
            expectedSeq += 1
        }
        return report
    }

    // MARK: - payload decoding helpers

    private func captureFromPayload(_ p: JSONValue) -> Capture? {
        guard let id = p["id"]?.stringValue,
              case .int(let seq)? = p["sequence_number"],
              let createdAt = p["created_at"]?.stringValue,
              let timezone = p["timezone"]?.stringValue,
              let observation = p["observation"]?.stringValue,
              let phenomenology = p["phenomenology"]?.stringValue,
              let action = p["action"]?.stringValue,
              let protocolVersion = p["protocol_version"]?.stringValue,
              let schemaVersion = p["schema_version"]?.stringValue,
              let previousHash = p["previous_hash"]?.stringValue,
              let committedAt = p["committed_at"]?.stringValue,
              let digest = p["integrity_hash"]?.stringValue else { return nil }
        var snapshot = ContextSnapshot()
        if case .object(let auto)? = p["context_snapshot"]?["automatic"] {
            snapshot.automatic = auto
        }
        if case .object(let stated)? = p["context_snapshot"]?["stated"] {
            snapshot.stated = stated
        }
        return Capture(
            id: id, sequenceNumber: Int(seq), createdAt: createdAt,
            recordedAt: p["recorded_at"]?.stringValue, timezone: timezone,
            observation: observation, phenomenology: phenomenology, action: action,
            source: p["source"]?.stringValue,
            recallLatency: p["recall_latency"]?.stringValue,
            protocolVersion: protocolVersion, schemaVersion: schemaVersion,
            contextSnapshot: snapshot, previousHash: previousHash,
            committedAt: committedAt, integrityHash: digest)
    }

    private func annotationFromPayload(_ p: JSONValue) -> Annotation? {
        guard let id = p["id"]?.stringValue,
              let captureID = p["capture_id"]?.stringValue,
              let createdAt = p["created_at"]?.stringValue,
              let type = p["type"]?.stringValue,
              let body = p["body"]?.stringValue,
              let digest = p["integrity_hash"]?.stringValue else { return nil }
        return Annotation(id: id, captureID: captureID, createdAt: createdAt,
                          type: type, body: body,
                          protocolVersion: Morningstar.protocolVersion,
                          integrityHash: digest)
    }

    private func interpretationFromPayload(_ p: JSONValue) -> Interpretation? {
        guard let id = p["id"]?.stringValue,
              let createdAt = p["created_at"]?.stringValue,
              let digest = p["integrity_hash"]?.stringValue,
              let revPayload = p["revision"],
              let revision = revisionFromPayload(revPayload) else { return nil }
        return Interpretation(
            id: id, createdAt: createdAt,
            parentInterpretationID: p["parent_interpretation_id"]?.stringValue,
            protocolVersion: Morningstar.protocolVersion,
            integrityHash: digest, revisions: [revision])
    }

    private func revisionFromPayload(_ p: JSONValue) -> InterpretationRevision? {
        guard let id = p["id"]?.stringValue,
              let interpretationID = p["interpretation_id"]?.stringValue,
              case .int(let revision)? = p["revision"],
              let createdAt = p["created_at"]?.stringValue,
              let title = p["title"]?.stringValue,
              let body = p["body"]?.stringValue,
              let status = p["status"]?.stringValue,
              case .array(let refs)? = p["referenced_capture_ids"] else { return nil }
        var confidence: Double?
        if case .double(let c)? = p["confidence"] { confidence = c }
        if case .int(let c)? = p["confidence"] { confidence = Double(c) }
        // Revision payloads in the ledger don't carry integrity_hash inside
        // hashContent; recompute for the materialized struct.
        let rev = InterpretationRevision(
            id: id, interpretationID: interpretationID, revision: Int(revision),
            createdAt: createdAt, title: title, body: body,
            referencedCaptureIDs: refs.compactMap { $0.stringValue },
            status: status, confidence: confidence,
            protocolVersion: Morningstar.protocolVersion, integrityHash: "")
        let digest = (try? integrityHash(rev.hashContent)) ?? ""
        return InterpretationRevision(
            id: id, interpretationID: interpretationID, revision: Int(revision),
            createdAt: createdAt, title: title, body: body,
            referencedCaptureIDs: refs.compactMap { $0.stringValue },
            status: status, confidence: confidence,
            protocolVersion: Morningstar.protocolVersion, integrityHash: digest)
    }
}

private func nilIfEmpty(_ s: String?) -> String? {
    guard let s, !s.isEmpty else { return nil }
    return s
}
