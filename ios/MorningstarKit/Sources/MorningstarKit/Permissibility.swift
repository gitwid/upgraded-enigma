/// Contextual permissibility — the v0.4 membrane.
///
/// The organizing question is not *who may grant this* but *what may
/// legitimately occur here, given this actor, this action, this environment,
/// this consent, and these constraints*.
///
/// **Permissibility is normative; permeability is technical.** A technically
/// possible operation may still be impermissible. Nothing in this file
/// weakens a technical boundary: the SQLite append-only triggers and the
/// hash chain remain the hard enforcement, and permissibility is evaluated
/// *in addition to* them, never instead of them.
///
/// Assessments live apart from captures on purpose. An assessment may be
/// superseded as context changes; the observation it was made about must
/// never be silently rewritten. That is the same separation the
/// interpretation layer already keeps between evidence and conclusions.

import Foundation

/// How the membrane responds. These are descriptions of a posture, not
/// permission levels — `edge` is not "high security", it is "this does not
/// happen here".
public enum Regime: String, Equatable, Sendable, CaseIterable {
    /// Accommodation: accept ambiguity, friction, and harmless variation
    /// without escalating.
    case sponge
    /// Legible resistance: make the approaching constraint perceptible, and
    /// offer adjustment or withdrawal rather than silent failure.
    case pressure
    /// Inviolable boundary: prevent the impermissible, including prohibited
    /// acquisition or disclosure.
    case edge
}

public enum Permissibility: Equatable, Sendable {
    case permitted
    /// Permitted only while every named condition holds. The conditions are
    /// stated so they can be shown to the person, not buried in a predicate.
    case conditional([String])
    case impermissible(String)
    /// Not yet decided. Deliberately distinct from `permitted` — see
    /// `mayProceed`, where it never becomes implicit permission for a
    /// sensitive action.
    case undetermined

    public var regime: Regime {
        switch self {
        case .permitted: return .sponge
        case .conditional: return .pressure
        case .impermissible: return .edge
        // Undetermined is pressure, not sponge: the person should be able to
        // feel that something is unresolved rather than discover it failed.
        case .undetermined: return .pressure
        }
    }

    /// Stable tag for storage; the payload travels separately so the stored
    /// form stays queryable.
    public var tag: String {
        switch self {
        case .permitted: return "permitted"
        case .conditional: return "conditional"
        case .impermissible: return "impermissible"
        case .undetermined: return "undetermined"
        }
    }
}

public enum Consent: String, Equatable, Sendable {
    case granted
    case refused
    /// Never silently read as granted.
    case unknown
}

/// What a sensitive action does with information. The brief's three verbs:
/// acquisition, retention, disclosure. Anything else is ordinary and may be
/// accommodated without ceremony.
public enum ActionClass: String, Equatable, Sendable, CaseIterable {
    case acquisition
    case retention
    case disclosure
    case ordinary

    public var isSensitive: Bool { self != .ordinary }
}

public struct InteractionContext: Equatable, Sendable {
    public let actorID: UUID
    public let action: String
    public let actionClass: ActionClass
    public let environmentID: UUID
    public let consent: Consent
    /// Conditions that must hold for the action to remain permitted. Stated
    /// in plain language because they are meant to be read by a person.
    public let constraints: [String]
    /// Captures this assessment was made in light of. Provenance: an
    /// assessment that cites no evidence says so, rather than implying some.
    public let evidenceIDs: [String]

    public init(actorID: UUID, action: String, actionClass: ActionClass,
                environmentID: UUID, consent: Consent,
                constraints: [String] = [], evidenceIDs: [String] = []) {
        self.actorID = actorID
        self.action = action
        self.actionClass = actionClass
        self.environmentID = environmentID
        self.consent = consent
        self.constraints = constraints
        self.evidenceIDs = evidenceIDs
    }
}

public struct PermissibilityAssessment: Equatable, Sendable {
    public let id: String
    public let actorID: UUID
    public let action: String
    public let actionClass: ActionClass
    public let environmentID: UUID
    public let consent: Consent
    public let constraints: [String]
    public let evidenceIDs: [String]
    public let result: Permissibility
    public let regime: Regime
    public let assessedAt: String
    /// After this instant the assessment is stale and degrades to
    /// `.undetermined` — it does not keep granting permission by inertia.
    public let validUntil: String?
    public let protocolVersion: String
    public let integrityHash: String

    public init(id: String, actorID: UUID, action: String, actionClass: ActionClass,
                environmentID: UUID, consent: Consent, constraints: [String],
                evidenceIDs: [String], result: Permissibility, regime: Regime,
                assessedAt: String, validUntil: String?,
                protocolVersion: String, integrityHash: String) {
        self.id = id
        self.actorID = actorID
        self.action = action
        self.actionClass = actionClass
        self.environmentID = environmentID
        self.consent = consent
        self.constraints = constraints
        self.evidenceIDs = evidenceIDs
        self.result = result
        self.regime = regime
        self.assessedAt = assessedAt
        self.validUntil = validUntil
        self.protocolVersion = protocolVersion
        self.integrityHash = integrityHash
    }

    /// The content dict this assessment's hash covers. `validUntil` and the
    /// result payload are included: a changed expiry or a changed reason is a
    /// different assessment, not an edit to this one.
    public var hashContent: JSONValue {
        var detail: JSONValue = .null
        if case .conditional(let conditions) = result {
            detail = .array(conditions.map { .string($0) })
        }
        if case .impermissible(let reason) = result {
            detail = .string(reason)
        }
        return .object([
            "id": .string(id),
            "actor_id": .string(actorID.uuidString.lowercased()),
            "action": .string(action),
            "action_class": .string(actionClass.rawValue),
            "environment_id": .string(environmentID.uuidString.lowercased()),
            "consent": .string(consent.rawValue),
            "constraints": .array(constraints.map { .string($0) }),
            "evidence_ids": .array(evidenceIDs.map { .string($0) }),
            "result": .string(result.tag),
            "result_detail": detail,
            "regime": .string(regime.rawValue),
            "assessed_at": .string(assessedAt),
            "valid_until": validUntil.map { .string($0) } ?? .null,
        ])
    }

    /// Whether the assessment has passed its own expiry.
    public func isStale(at instant: Date = Date()) -> Bool {
        guard let validUntil, let deadline = Timestamp.date(validUntil) else { return false }
        return instant > deadline
    }

    /// The result as it stands *now*. A stale assessment does not keep
    /// granting permission; it reverts to undecided.
    public func effectiveResult(at instant: Date = Date()) -> Permissibility {
        isStale(at: instant) ? .undetermined : result
    }
}

/// The evaluation rules, kept pure so they can be reasoned about and tested
/// without a store. Order matters, and the order is the point: refusal
/// outranks everything, and an unresolved sensitive action is never
/// accommodated into permission.
public enum PermissibilityPolicy {

    public static func assess(_ context: InteractionContext) -> Permissibility {
        // 1. Refusal is an edge, always. No regime, metaphor, or constraint
        //    list softens a withdrawn consent.
        if context.consent == .refused {
            return .impermissible("consent refused for \(context.action)")
        }
        // 2. A sensitive action without consent is undetermined — never
        //    permitted by default, and never silently accommodated.
        if context.actionClass.isSensitive && context.consent == .unknown {
            return .undetermined
        }
        // 3. Named constraints make the boundary perceptible rather than
        //    letting the person walk into it.
        if !context.constraints.isEmpty {
            return .conditional(context.constraints)
        }
        // 4. Otherwise accommodate.
        return .permitted
    }

    /// Whether an action may actually proceed.
    ///
    /// `conditionsSatisfied` is supplied by the caller because this layer
    /// cannot verify conditions it only names; a caller that cannot confirm
    /// them must pass `false`.
    public static func mayProceed(_ result: Permissibility,
                                  actionClass: ActionClass,
                                  conditionsSatisfied: Bool = false) -> Bool {
        switch result {
        case .permitted:
            return true
        case .conditional:
            return conditionsSatisfied
        case .impermissible:
            return false
        case .undetermined:
            // Sponge accommodates harmless variation; it does not accommodate
            // acquisition, retention, or disclosure on an unanswered question.
            return !actionClass.isSensitive
        }
    }

    /// Which of two assessments governs. Recency wins, because context moves;
    /// but a tie resolves to the more restrictive, so a race cannot widen
    /// permission.
    public static func governing(_ a: PermissibilityAssessment,
                                 _ b: PermissibilityAssessment,
                                 at instant: Date = Date()) -> PermissibilityAssessment {
        if a.assessedAt != b.assessedAt {
            return a.assessedAt > b.assessedAt ? a : b
        }
        return restrictiveness(a.effectiveResult(at: instant))
            >= restrictiveness(b.effectiveResult(at: instant)) ? a : b
    }

    static func restrictiveness(_ result: Permissibility) -> Int {
        switch result {
        case .permitted: return 0
        case .conditional: return 1
        case .undetermined: return 2
        case .impermissible: return 3
        }
    }
}
