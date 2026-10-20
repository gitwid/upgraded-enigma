import XCTest
@testable import MorningstarKit

/// Protocol 0.4 — contextual permissibility.
///
/// These tests target the items the handoff left OPEN: consent withdrawn
/// during an in-flight operation, conflicting assessments, and stale
/// permissions. What they establish is bounded and stated honestly in
/// `testConcurrencyClaimIsBoundedToOneConnection`: serialization on a single
/// connection, not distributed consent or identity verification.
final class PermissibilityTests: XCTestCase {

    var directory: URL!
    var store: SQLiteStore!
    let actor = UUID()
    let environment = UUID()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("morningstar-perm-\(UUID().uuidString)")
        store = try SQLiteStore(directory: directory)
    }

    override func tearDownWithError() throws {
        store?.close()
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func context(_ action: String = "export archive",
                 _ actionClass: ActionClass = .disclosure,
                 consent: Consent = .granted,
                 constraints: [String] = [],
                 evidence: [String] = []) -> InteractionContext {
        InteractionContext(actorID: actor, action: action, actionClass: actionClass,
                           environmentID: environment, consent: consent,
                           constraints: constraints, evidenceIDs: evidence)
    }

    // MARK: - the policy, in isolation

    func testRefusalIsAlwaysAnEdgeRegardlessOfContext() {
        for actionClass in ActionClass.allCases {
            let result = PermissibilityPolicy.assess(
                context("anything", actionClass, consent: .refused,
                        constraints: ["a constraint that must not rescue this"]))
            guard case .impermissible = result else {
                return XCTFail("refusal must be impermissible for \(actionClass)")
            }
            XCTAssertEqual(result.regime, .edge)
            XCTAssertFalse(PermissibilityPolicy.mayProceed(
                result, actionClass: actionClass, conditionsSatisfied: true),
                "satisfied conditions must not override a refusal")
        }
    }

    /// The interrupt: a softer interaction metaphor must not weaken a hard
    /// consent boundary.
    func testUndeterminedIsNeverImplicitPermissionForSensitiveActions() {
        for actionClass in [ActionClass.acquisition, .retention, .disclosure] {
            let result = PermissibilityPolicy.assess(
                context("collect", actionClass, consent: .unknown))
            XCTAssertEqual(result, .undetermined)
            XCTAssertFalse(PermissibilityPolicy.mayProceed(result, actionClass: actionClass))
        }
        // Sponge still accommodates harmless variation.
        let ordinary = PermissibilityPolicy.assess(
            context("scroll the archive", .ordinary, consent: .unknown))
        XCTAssertTrue(PermissibilityPolicy.mayProceed(ordinary, actionClass: .ordinary))
    }

    func testUndeterminedReadsAsPressureSoItIsPerceptible() {
        // Unresolved should be felt, not silently accommodated and then failed.
        XCTAssertEqual(Permissibility.undetermined.regime, .pressure)
        XCTAssertEqual(Permissibility.permitted.regime, .sponge)
        XCTAssertEqual(Permissibility.conditional(["x"]).regime, .pressure)
        XCTAssertEqual(Permissibility.impermissible("x").regime, .edge)
    }

    func testConditionalRequiresTheCallerToConfirmTheConditions() {
        let result = PermissibilityPolicy.assess(
            context("share with clinician", .disclosure, consent: .granted,
                    constraints: ["recipient is the named clinician"]))
        XCTAssertEqual(result, .conditional(["recipient is the named clinician"]))
        XCTAssertFalse(PermissibilityPolicy.mayProceed(result, actionClass: .disclosure))
        XCTAssertTrue(PermissibilityPolicy.mayProceed(
            result, actionClass: .disclosure, conditionsSatisfied: true))
    }

    // MARK: - assessments as records

    func testAssessmentIsRecordedAppendOnlyAndVerifies() throws {
        let capture = try store.commitCapture(observation: "the session ended early")
        let assessment = try store.assess(
            context("export archive", .disclosure, consent: .granted, evidence: [capture.id]))
        XCTAssertEqual(assessment.result, .permitted)
        XCTAssertEqual(assessment.regime, .sponge)
        XCTAssertEqual(assessment.evidenceIDs, [capture.id])

        // It is on the ledger as its own event…
        XCTAssertTrue(try store.events().contains {
            $0.string("event_type") == "permissibility_assessed"
        })
        // …and the table refuses edits, like every other evidential table.
        for sql in ["UPDATE permissibility_assessments SET result='permitted'",
                    "DELETE FROM permissibility_assessments"] {
            XCTAssertThrowsError(try store.connection.execute(sql), sql) { error in
                XCTAssertTrue((error as? SQLiteError)?.isAppendOnlyViolation == true)
            }
        }
        let report = try store.verifyIntegrity()
        XCTAssertTrue(report.ok, "\(report.errors)")
        XCTAssertEqual(report.assessmentCount, 1)
    }

    func testAssessingDoesNotTouchTheCapture() throws {
        let capture = try store.commitCapture(observation: "evidence")
        let before = try store.capture(id: capture.id)
        try store.assess(context("export archive", .disclosure, consent: .refused,
                                 evidence: [capture.id]))
        XCTAssertEqual(try store.capture(id: capture.id), before)
        XCTAssertEqual(try store.assessments(forCapture: capture.id).count, 1)
        XCTAssertTrue(try store.verifyIntegrity().ok)
    }

    func testAssessmentCitingAMissingCaptureIsRejected() throws {
        XCTAssertThrowsError(try store.assess(
            context("export archive", .disclosure, consent: .granted,
                    evidence: ["00000000-0000-4000-8000-000000000000"])))
    }

    // MARK: - OPEN: withdrawal during an in-flight operation

    func testConsentWithdrawnMidFlightStopsTheNextStep() throws {
        try store.assess(context("export archive", .disclosure, consent: .granted))
        var completedSteps = 0

        // A multi-step operation that re-checks before each sensitive step,
        // which is the only way withdrawal can land mid-flight.
        func step() throws {
            try store.withPermission(actorID: actor, action: "export archive",
                                     actionClass: .disclosure, environmentID: environment) {
                completedSteps += 1
            }
        }
        try step()
        XCTAssertEqual(completedSteps, 1)

        // Consent is withdrawn between steps.
        try store.assess(context("export archive", .disclosure, consent: .refused))

        XCTAssertThrowsError(try step()) { error in
            guard let refusal = error as? PermissibilityError,
                  case .refused(_, let result, let regime) = refusal else {
                return XCTFail("wrong error: \(error)")
            }
            guard case .impermissible = result else { return XCTFail("expected impermissible") }
            XCTAssertEqual(regime, .edge)
        }
        XCTAssertEqual(completedSteps, 1, "the step after withdrawal must not run")
        // Both judgements remain on record — the grant is not erased by the refusal.
        XCTAssertTrue(try store.verifyIntegrity().ok)
    }

    func testWithdrawalIsVisibleToAnOperationAlreadyInsideTheStore() throws {
        try store.assess(context("export archive", .disclosure, consent: .granted))
        var ran = false
        // The re-read happens inside the transaction, so a refusal recorded
        // before the body starts is seen rather than raced past.
        try store.assess(context("export archive", .disclosure, consent: .refused))
        XCTAssertThrowsError(try store.withPermission(
            actorID: actor, action: "export archive",
            actionClass: .disclosure, environmentID: environment) { ran = true })
        XCTAssertFalse(ran)
    }

    // MARK: - OPEN: conflicting and stale assessments

    func testLaterAssessmentGovernsAndTiesResolveToTheMoreRestrictive() throws {
        try store.assess(context("export archive", .disclosure, consent: .granted))
        try store.assess(context("export archive", .disclosure, consent: .refused))
        let governing = try store.governingAssessment(
            actorID: actor, action: "export archive", environmentID: environment)
        guard case .impermissible? = governing?.result else {
            return XCTFail("the later refusal must govern")
        }

        // A tie cannot widen permission.
        let now = Timestamp.now()
        let permissive = PermissibilityAssessment(
            id: "a", actorID: actor, action: "x", actionClass: .disclosure,
            environmentID: environment, consent: .granted, constraints: [], evidenceIDs: [],
            result: .permitted, regime: .sponge, assessedAt: now, validUntil: nil,
            protocolVersion: "0.4", integrityHash: "")
        let restrictive = PermissibilityAssessment(
            id: "b", actorID: actor, action: "x", actionClass: .disclosure,
            environmentID: environment, consent: .refused, constraints: [], evidenceIDs: [],
            result: .impermissible("no"), regime: .edge, assessedAt: now, validUntil: nil,
            protocolVersion: "0.4", integrityHash: "")
        XCTAssertEqual(PermissibilityPolicy.governing(permissive, restrictive).id, "b")
        XCTAssertEqual(PermissibilityPolicy.governing(restrictive, permissive).id, "b")
    }

    func testStalePermissionDegradesToUndeterminedRatherThanPersisting() throws {
        let expired = PermissibilityAssessment(
            id: "stale", actorID: actor, action: "export archive", actionClass: .disclosure,
            environmentID: environment, consent: .granted, constraints: [], evidenceIDs: [],
            result: .permitted, regime: .sponge,
            assessedAt: Timestamp.formatter.string(from: Date().addingTimeInterval(-7200)),
            validUntil: Timestamp.formatter.string(from: Date().addingTimeInterval(-3600)),
            protocolVersion: "0.4", integrityHash: "")
        XCTAssertTrue(expired.isStale())
        XCTAssertEqual(expired.effectiveResult(), .undetermined)
        XCTAssertFalse(PermissibilityPolicy.mayProceed(
            expired.effectiveResult(), actionClass: .disclosure))

        // And through the store: a permission that has expired stops the action.
        try store.assess(context("fetch weather", .acquisition, consent: .granted),
                         validFor: -1)
        XCTAssertThrowsError(try store.withPermission(
            actorID: actor, action: "fetch weather",
            actionClass: .acquisition, environmentID: environment) { })
        let report = try store.verifyIntegrity()
        XCTAssertTrue(report.ok, "\(report.errors)")
        XCTAssertTrue(report.warnings.contains { $0.contains("expired") }, "\(report.warnings)")
    }

    func testNoAssessmentAtAllIsUndeterminedNotPermitted() throws {
        XCTAssertNil(try store.governingAssessment(
            actorID: actor, action: "never assessed", environmentID: environment))
        XCTAssertThrowsError(try store.withPermission(
            actorID: actor, action: "never assessed",
            actionClass: .disclosure, environmentID: environment) { })
        // An ordinary action is still accommodated.
        var ran = false
        try store.withPermission(actorID: actor, action: "never assessed",
                                 actionClass: .ordinary, environmentID: environment) { ran = true }
        XCTAssertTrue(ran)
    }

    /// States the limit of what these tests establish, so the register stays
    /// honest: this is serialization on one connection, not distributed
    /// consent, identity verification, or multi-process enforcement.
    func testConcurrencyClaimIsBoundedToOneConnection() throws {
        try store.assess(context("export archive", .disclosure, consent: .granted))
        var observedInside: Permissibility?
        try store.withPermission(actorID: actor, action: "export archive",
                                 actionClass: .disclosure, environmentID: environment) {
            // Re-reading inside the body sees the same governing assessment the
            // guard used, because the transaction holds for the body's duration.
            observedInside = try store.governingAssessment(
                actorID: actor, action: "export archive",
                environmentID: environment)?.effectiveResult()
        }
        XCTAssertEqual(observedInside, .permitted)
    }

    // MARK: - the rest of the instrument is untouched

    func testPermissibilityDoesNotWeakenExistingEnforcement() throws {
        let capture = try store.commitCapture(observation: "still immutable")
        try store.assess(context("rewrite", .ordinary, consent: .granted))
        // Captures remain append-only at the database level, assessment or not.
        XCTAssertThrowsError(try store.connection.execute(
            "UPDATE captures SET observation='rewritten' WHERE id=?", [.text(capture.id)]))
        XCTAssertEqual(try store.capture(id: capture.id).observation, "still immutable")
        XCTAssertTrue(try store.verifyIntegrity().ok)
    }

    func testVersionsRunThroughOhFourAndOlderCapturesStillVerify() throws {
        XCTAssertEqual(store.schemaVersion, "0.4")
        XCTAssertEqual(try store.protocolVersions().compactMap { $0.string("version") },
                       ["0.1", "0.2", "0.3", "0.4"])
        // A 0.3-era capture, hashed over the 0.3 field set, still verifies.
        let now = Timestamp.now()
        let content = Capture.hashContent(
            id: "legacy-0-3", sequenceNumber: 1, createdAt: now, recordedAt: nil,
            timezone: "UTC", observation: "before 0.4", phenomenology: "", action: "",
            source: nil, recallLatency: nil, protocolVersion: "0.3", schemaVersion: "0.3",
            contextSnapshot: ContextSnapshot(), previousHash: genesisHash,
            committedAt: now, unsorted: nil)
        let digest = try integrityHash(content)
        try store.connection.execute(
            """
            INSERT INTO captures
            (id, sequence_number, created_at, recorded_at, timezone, observation,
             phenomenology, action, source, recall_latency, protocol_version,
             schema_version, context_snapshot, integrity_hash, previous_hash, committed_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            [.text("legacy-0-3"), SQLValue(1), .text(now), .null, .text("UTC"),
             .text("before 0.4"), .text(""), .text(""), .null, .null,
             .text("0.3"), .text("0.3"),
             .text(try JCS.canonicalJSON(ContextSnapshot().jsonValue)),
             .text(digest), .text(genesisHash), .text(now)])
        let report = try store.verifyIntegrity()
        XCTAssertTrue(report.ok, "a 0.3 capture must still verify under 0.4: \(report.errors)")
    }
}
