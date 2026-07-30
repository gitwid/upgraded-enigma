/// Domain objects. Each type's `hashContent()` mirrors — field for
/// field — the content dictionaries built in the Python reference
/// implementation (`morningstar/store.py`), so integrity hashes are
/// byte-identical across implementations.

import Foundation

public enum Morningstar {
    public static let appVersion = "0.2.0"
    public static let protocolVersion = "0.2"
    public static let schemaVersion = "0.2"
}

public struct ContextSnapshot: Codable, Equatable, Sendable {
    public var automatic: [String: JSONValue]
    public var stated: [String: JSONValue]

    public init(automatic: [String: JSONValue] = [:], stated: [String: JSONValue] = [:]) {
        self.automatic = automatic
        self.stated = stated
    }

    public var jsonValue: JSONValue {
        .object(["automatic": .object(automatic), "stated": .object(stated)])
    }
}

public struct Capture: Equatable, Sendable {
    public let id: String
    public let sequenceNumber: Int
    public let createdAt: String
    public let recordedAt: String?
    public let timezone: String
    public let observation: String
    public let phenomenology: String
    public let action: String
    public let source: String?
    public let recallLatency: String?
    public let protocolVersion: String
    public let schemaVersion: String
    public let contextSnapshot: ContextSnapshot
    public let previousHash: String
    public let committedAt: String
    public let integrityHash: String

    /// Mirrors the capture content dict in store.py::commit_capture.
    public static func hashContent(
        id: String, sequenceNumber: Int, createdAt: String, recordedAt: String?,
        timezone: String, observation: String, phenomenology: String, action: String,
        source: String?, recallLatency: String?, protocolVersion: String,
        schemaVersion: String, contextSnapshot: ContextSnapshot,
        previousHash: String, committedAt: String
    ) -> JSONValue {
        .object([
            "id": .string(id),
            "sequence_number": .int(Int64(sequenceNumber)),
            "created_at": .string(createdAt),
            "recorded_at": recordedAt.map { .string($0) } ?? .null,
            "timezone": .string(timezone),
            "observation": .string(observation),
            "phenomenology": .string(phenomenology),
            "action": .string(action),
            "source": source.map { .string($0) } ?? .null,
            "recall_latency": recallLatency.map { .string($0) } ?? .null,
            "protocol_version": .string(protocolVersion),
            "schema_version": .string(schemaVersion),
            "context_snapshot": contextSnapshot.jsonValue,
            "previous_hash": .string(previousHash),
            "committed_at": .string(committedAt),
        ])
    }

    public var hashContent: JSONValue {
        Capture.hashContent(
            id: id, sequenceNumber: sequenceNumber, createdAt: createdAt,
            recordedAt: recordedAt, timezone: timezone, observation: observation,
            phenomenology: phenomenology, action: action, source: source,
            recallLatency: recallLatency, protocolVersion: protocolVersion,
            schemaVersion: schemaVersion, contextSnapshot: contextSnapshot,
            previousHash: previousHash, committedAt: committedAt)
    }
}

public struct Annotation: Equatable, Sendable {
    public let id: String
    public let captureID: String
    public let createdAt: String
    public let type: String     // note | correction | context
    public let body: String
    public let protocolVersion: String
    public let integrityHash: String

    /// Mirrors the annotation content dict in store.py::annotate.
    public var hashContent: JSONValue {
        .object([
            "id": .string(id),
            "capture_id": .string(captureID),
            "created_at": .string(createdAt),
            "type": .string(type),
            "body": .string(body),
        ])
    }
}

public struct InterpretationRevision: Equatable, Sendable {
    public let id: String
    public let interpretationID: String
    public let revision: Int
    public let createdAt: String
    public let title: String
    public let body: String
    public let referencedCaptureIDs: [String]
    public let status: String   // active | superseded | discarded
    public let confidence: Double?
    public let protocolVersion: String
    public let integrityHash: String

    /// Mirrors the revision content dict in store.py::_add_revision.
    public var hashContent: JSONValue {
        .object([
            "id": .string(id),
            "interpretation_id": .string(interpretationID),
            "revision": .int(Int64(revision)),
            "created_at": .string(createdAt),
            "title": .string(title),
            "body": .string(body),
            "referenced_capture_ids": .array(referencedCaptureIDs.map { .string($0) }),
            "status": .string(status),
            "confidence": confidence.map { .double($0) } ?? .null,
        ])
    }
}

public struct Interpretation: Equatable, Sendable {
    public let id: String
    public let createdAt: String
    public let parentInterpretationID: String?
    public let protocolVersion: String
    public let integrityHash: String
    public var revisions: [InterpretationRevision]

    public var current: InterpretationRevision { revisions.last! }

    /// Mirrors the base content dict in store.py::create_interpretation.
    public var hashContent: JSONValue {
        .object([
            "id": .string(id),
            "created_at": .string(createdAt),
            "parent_interpretation_id": parentInterpretationID.map { .string($0) } ?? .null,
        ])
    }
}

public struct InstrumentEvent: Equatable, Sendable {
    public let id: String
    public let seq: Int
    public let eventType: String
    public let createdAt: String
    public let payload: JSONValue
    public let protocolVersion: String
    public let schemaVersion: String
    public let previousHash: String
    public let integrityHash: String

    /// Mirrors the event content dict in store.py::_append_event.
    public var hashContent: JSONValue {
        .object([
            "id": .string(id),
            "seq": .int(Int64(seq)),
            "event_type": .string(eventType),
            "created_at": .string(createdAt),
            "payload": payload,
            "protocol_version": .string(protocolVersion),
            "schema_version": .string(schemaVersion),
            "previous_hash": .string(previousHash),
        ])
    }
}

// MARK: - JSONValue Codable bridge (for app-level persistence of drafts etc.)

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let i = try? container.decode(Int64.self) { self = .int(i) }
        else if let d = try? container.decode(Double.self) { self = .double(d) }
        else if let s = try? container.decode(String.self) { self = .string(s) }
        else if let a = try? container.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}
