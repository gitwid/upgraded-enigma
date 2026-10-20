/// Types shared by the store implementations.

import Foundation

public enum StoreError: Error, Equatable, CustomStringConvertible {
    case notFound(String)
    case corruptLedger(String)
    case invalidStatus(String)

    public var description: String {
        switch self {
        case .notFound(let what): return "not found: \(what)"
        case .corruptLedger(let why): return "corrupt ledger: \(why)"
        case .invalidStatus(let status): return "invalid status: \(status)"
        }
    }
}

/// Raised when a schema change would violate the protocol's versioning rule.
/// Schema mutation without a version increment is an instrument failure, so
/// it is refused rather than reported.
public enum SchemaVersionError: Error, Equatable, CustomStringConvertible {
    case notSequential(expected: Int, got: Int)
    case versionAlreadyRegistered(String)

    public var description: String {
        switch self {
        case .notSequential(let expected, let got):
            return "migration id \(got) does not follow \(expected - 1); "
                + "schema changes must be sequential"
        case .versionAlreadyRegistered(let version):
            return "schema version \(version) is already registered; "
                + "a schema change requires a new version record"
        }
    }
}

/// Raised when an action is stopped because the context does not permit it.
/// It carries the regime so the caller can respond in kind: accommodate,
/// make the resistance legible, or stop at the edge.
public enum PermissibilityError: Error, CustomStringConvertible {
    case refused(action: String, result: Permissibility, regime: Regime)

    public var description: String {
        guard case .refused(let action, let result, let regime) = self else { return "refused" }
        switch result {
        case .impermissible(let reason):
            return "\(action) is impermissible here: \(reason)"
        case .undetermined:
            return "\(action) is not permitted because permissibility is undetermined "
                + "— an unanswered question is not consent (\(regime.rawValue))"
        case .conditional(let conditions):
            return "\(action) is permitted only while: \(conditions.joined(separator: "; "))"
        case .permitted:
            return "\(action) was refused despite being permitted — this is a bug"
        }
    }
}

/// The result of re-verifying a store. Integrity conditions are instrument
/// states, not user failures: `warnings` are informational (redactions,
/// hidden captures, objects only the reference implementation can verify),
/// while `errors` mean the record no longer verifies.
public struct IntegrityReport: Equatable, Sendable {
    public var ok: Bool { errors.isEmpty }
    public var checkedAt: String = ""
    public var errors: [String] = []
    public var warnings: [String] = []
    public var eventCount = 0
    public var captureCount = 0
    public var annotationCount = 0
    public var interpretationCount = 0
    public var schemaVersionCount = 0
    public var protocolVersionCount = 0
    public var assessmentCount = 0

    public init() {}
}

/// Optional context the operator may state; anything else is dropped rather
/// than silently stored (mirrors STATED_CONTEXT_KEYS in the reference).
public let statedContextKeys = ["location", "weather", "sleep_duration", "heart_rate"]

public let annotationTypes = ["note", "correction", "context"]
public let interpretationStatuses = ["active", "superseded", "discarded"]

/// Placeholder left in place of permanently deleted content.
public let redactedPlaceholder = "[redacted]"

enum Timestamp {
    static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    static func now() -> String { formatter.string(from: Date()) }

    static func date(_ string: String) -> Date? { formatter.date(from: string) }
}
