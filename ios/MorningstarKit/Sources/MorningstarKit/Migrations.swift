/// Schema migrations — a mirror of `morningstar/morningstar/migrations.py`.
///
/// Migrations are ordinary data so each one carries the metadata the
/// protocol requires (description, migration notes, compatibility notes).
/// Applying one writes a `schema_migrations` row and appends a
/// `schema_migrated` event: a schema change is itself an observable,
/// first-class event. A migration that reuses an already-registered schema
/// version is rejected — schema mutation without a version increment is an
/// instrument failure.
///
/// The DDL and trigger text are kept identical to the reference so a
/// database written by either implementation is the same database.

public struct ProtocolRecord: Sendable {
    public let version: String
    public let changeDescription: String
    public let migrationNotes: String
    public let compatibilityNotes: String
}

public struct Migration: Sendable {
    public let id: Int
    public let schemaVersion: String
    public let description: String
    public let migrationNotes: String
    public let compatibilityNotes: String
    public let statements: [String]
    /// A protocol change riding along with this migration, registered as a
    /// first-class event when it is applied. Versions are pinned here
    /// explicitly — never read from the runtime constant — so replaying all
    /// migrations reconstructs the full version history.
    public let protocolRecord: ProtocolRecord?

    public init(id: Int, schemaVersion: String, description: String,
                migrationNotes: String, compatibilityNotes: String,
                statements: [String], protocolRecord: ProtocolRecord? = nil) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.description = description
        self.migrationNotes = migrationNotes
        self.compatibilityNotes = compatibilityNotes
        self.statements = statements
        self.protocolRecord = protocolRecord
    }
}

/// Triggers enforce append-only behavior at the database level. The `_guard`
/// table is a maintenance latch: empty in normal operation, and only the
/// sanctioned redaction path inserts the unlock row, for the duration of a
/// single transaction. Deleting rows is never allowed, latch or no latch —
/// redaction blanks content but preserves the chain.
func immutableTriggers(_ table: String, allowGuardedUpdate: Bool = false,
                       allowGuardedDelete: Bool = false) -> [String] {
    func clause(_ allowed: Bool) -> String {
        allowed
            ? "WHEN NOT EXISTS (SELECT 1 FROM _guard WHERE key = 'maintenance_unlocked')"
            : ""
    }
    return [
        """
        CREATE TRIGGER \(table)_no_update BEFORE UPDATE ON \(table)
            \(clause(allowGuardedUpdate))
            BEGIN SELECT RAISE(ABORT, 'integrity: \(table) rows are append-only'); END
        """,
        """
        CREATE TRIGGER \(table)_no_delete BEFORE DELETE ON \(table)
            \(clause(allowGuardedDelete))
            BEGIN SELECT RAISE(ABORT, 'integrity: \(table) rows may not be deleted'); END
        """,
    ]
}

let migration0001 = Migration(
    id: 1,
    schemaVersion: "0.1",
    description: """
        Initial Morningstar schema: append-only event ledger, captures, \
        annotations, interpretations with revision history, protocol and \
        schema version registries, visibility overlay, settings.
        """,
    migrationNotes: "Creates all tables from scratch; no data to migrate.",
    compatibilityNotes: "First schema version; nothing earlier exists.",
    statements: [
        "CREATE TABLE _guard (key TEXT PRIMARY KEY, value TEXT)",
        "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
        """
        CREATE TABLE schema_migrations (
            id INTEGER PRIMARY KEY,
            schema_version TEXT NOT NULL UNIQUE,
            applied_at TEXT NOT NULL,
            description TEXT NOT NULL,
            migration_notes TEXT NOT NULL,
            compatibility_notes TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE protocol_versions (
            id TEXT PRIMARY KEY,
            version TEXT NOT NULL UNIQUE,
            created_at TEXT NOT NULL,
            change_description TEXT NOT NULL,
            migration_notes TEXT NOT NULL,
            compatibility_notes TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE events (
            seq INTEGER PRIMARY KEY,
            id TEXT NOT NULL UNIQUE,
            event_type TEXT NOT NULL,
            created_at TEXT NOT NULL,
            payload TEXT NOT NULL,
            protocol_version TEXT NOT NULL,
            schema_version TEXT NOT NULL,
            integrity_hash TEXT NOT NULL,
            previous_hash TEXT NOT NULL,
            redacted INTEGER NOT NULL DEFAULT 0
        )
        """,
        """
        CREATE TABLE captures (
            id TEXT PRIMARY KEY,
            sequence_number INTEGER NOT NULL UNIQUE,
            created_at TEXT NOT NULL,
            recorded_at TEXT,
            timezone TEXT NOT NULL,
            observation TEXT NOT NULL,
            phenomenology TEXT NOT NULL,
            action TEXT NOT NULL,
            source TEXT,
            recall_latency TEXT,
            protocol_version TEXT NOT NULL,
            schema_version TEXT NOT NULL,
            context_snapshot TEXT NOT NULL,
            integrity_hash TEXT NOT NULL,
            previous_hash TEXT NOT NULL,
            committed_at TEXT NOT NULL,
            redacted INTEGER NOT NULL DEFAULT 0
        )
        """,
        // Visibility is a view preference, not evidence: deliberately
        // mutable, kept out of the captures table so evidence rows stay
        // frozen.
        """
        CREATE TABLE capture_visibility (
            capture_id TEXT PRIMARY KEY REFERENCES captures(id),
            hidden INTEGER NOT NULL DEFAULT 0,
            updated_at TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE annotations (
            id TEXT PRIMARY KEY,
            capture_id TEXT NOT NULL REFERENCES captures(id),
            created_at TEXT NOT NULL,
            type TEXT NOT NULL,
            body TEXT NOT NULL,
            integrity_hash TEXT NOT NULL,
            redacted INTEGER NOT NULL DEFAULT 0
        )
        """,
        """
        CREATE TABLE interpretations (
            id TEXT PRIMARY KEY,
            created_at TEXT NOT NULL,
            parent_interpretation_id TEXT REFERENCES interpretations(id),
            integrity_hash TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE interpretation_revisions (
            id TEXT PRIMARY KEY,
            interpretation_id TEXT NOT NULL REFERENCES interpretations(id),
            revision INTEGER NOT NULL,
            created_at TEXT NOT NULL,
            title TEXT NOT NULL,
            body TEXT NOT NULL,
            referenced_capture_ids TEXT NOT NULL,
            status TEXT NOT NULL CHECK (status IN ('active','superseded','discarded')),
            confidence REAL,
            integrity_hash TEXT NOT NULL,
            UNIQUE (interpretation_id, revision)
        )
        """,
    ]
        + immutableTriggers("events", allowGuardedUpdate: true)
        + immutableTriggers("captures", allowGuardedUpdate: true)
        + immutableTriggers("annotations", allowGuardedUpdate: true)
        + immutableTriggers("interpretations")
        + immutableTriggers("interpretation_revisions")
        + immutableTriggers("schema_migrations")
        + immutableTriggers("protocol_versions"),
    protocolRecord: ProtocolRecord(
        version: "0.1",
        changeDescription: """
            Initial Morningstar capture protocol: four channels (observation, \
            phenomenology, action, context); interpretation is a separate layer.
            """,
        migrationNotes: "Nothing to migrate.",
        compatibilityNotes: "First protocol version.")
)

let migration0002 = Migration(
    id: 2,
    schemaVersion: "0.2",
    description: """
        Adds protocol_version columns to annotations, interpretations, and \
        interpretation revisions so every stored object records the protocol \
        it was hashed under.
        """,
    migrationNotes: """
        Additive only. Existing rows keep NULL protocol_version and are \
        treated as protocol 0.1 (legacy canonicalization) by the integrity \
        checker. No hashes are recomputed.
        """,
    compatibilityNotes: """
        Objects written under schema/protocol 0.1 remain readable and \
        verifiable forever using the original serialization.
        """,
    statements: [
        "ALTER TABLE annotations ADD COLUMN protocol_version TEXT",
        "ALTER TABLE interpretations ADD COLUMN protocol_version TEXT",
        "ALTER TABLE interpretation_revisions ADD COLUMN protocol_version TEXT",
    ],
    protocolRecord: ProtocolRecord(
        version: "0.2",
        changeDescription: """
            Canonical serialization for integrity hashing is now RFC 8785 \
            (JSON Canonicalization Scheme). The golden vectors in \
            tests/golden/jcs_vectors.json define the byte-exact contract any \
            future implementation (e.g. a native Swift port) must reproduce.
            """,
        migrationNotes: """
            New objects are hashed over JCS bytes. Objects hashed under \
            protocol 0.1 keep their original hashes and are verified with the \
            original serialization — re-hashing history would be later \
            knowledge rewriting earlier evidence.
            """,
        compatibilityNotes: """
            Integrity verification selects the canonicalization by each \
            object's recorded protocol version. Hash-chain continuity is \
            unaffected: chains compare stored hash strings.
            """)
)

let migration0003 = Migration(
    id: 3,
    schemaVersion: "0.3",
    description: """
        Adds the `unsorted` capture channel, for text recorded at event speed \
        that has not been separated into observation, phenomenology, and action.
        """,
    migrationNotes: """
        Additive only. Existing captures keep NULL and are unaffected: the \
        column joins hashed content only from protocol 0.3, and every object's \
        content is rebuilt from its own recorded version, so captures written \
        under 0.2 keep verifying against their original hashes. Nothing is \
        recomputed.
        """,
    compatibilityNotes: """
        A 0.2 reader encountering a 0.3 capture will not see the unsorted text \
        and will compute a different hash for it; it should verify objects only \
        up to the protocol version it implements rather than reporting them \
        as tampered.
        """,
    statements: [
        "ALTER TABLE captures ADD COLUMN unsorted TEXT",
    ],
    protocolRecord: ProtocolRecord(
        version: "0.3",
        changeDescription: """
            Captures may record an `unsorted` channel: one piece of text taken \
            down at event speed, explicitly not yet separated into layers. The \
            protocol has always recorded recall latency as an admission that \
            memory degrades between an event and the writing of it; this makes \
            the fast path a first-class capture instead of leaving speed and \
            structure in conflict.
            """,
        migrationNotes: """
            `unsorted` enters hashed capture content at 0.3. Content for \
            earlier objects is built without it, so their hashes are unchanged \
            and still verify.
            """,
        compatibilityNotes: """
            Sorting an unsorted capture later never edits it: the separation is \
            recorded as an annotation, because deciding what was observation \
            and what was interpretation is later knowledge about the evidence, \
            not the evidence.
            """)
)

public let migrations: [Migration] = [migration0001, migration0002, migration0003]
