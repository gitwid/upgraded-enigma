"""Schema migrations.

Migrations are ordinary Python data so that each one carries the
metadata the protocol requires (description, migration notes,
compatibility notes). Applying a migration writes a row to
``schema_migrations`` and appends a ``schema_migrated`` event — a
schema change is itself an observable, first-class event. A migration
that reuses an already-registered schema version is rejected: schema
mutation without a version increment is an instrument failure.

Historical rows are never rewritten by a migration; new schema
versions may only add structure. Every capture keeps the schema
version that was active when it was committed.
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class ProtocolRecord:
    version: str
    change_description: str
    migration_notes: str
    compatibility_notes: str


@dataclass(frozen=True)
class Migration:
    id: int
    schema_version: str
    description: str
    migration_notes: str
    compatibility_notes: str
    statements: tuple[str, ...]
    # A protocol change that rides along with this migration, registered
    # as a first-class event when the migration is applied. Versions are
    # pinned here explicitly — never derived from the runtime constant —
    # so replaying all migrations on a fresh store reconstructs the full
    # version history.
    protocol: ProtocolRecord | None = None


# Triggers enforce append-only behavior at the database level. The
# `_guard` table acts as a maintenance latch: it is empty in normal
# operation, and only the sanctioned redaction path inserts the unlock
# row for the duration of a single transaction. Deleting event rows is
# never allowed, latch or no latch — redaction blanks payloads but
# preserves the chain.
def _immutable(table: str, *, allow_guarded_update: bool = False,
               allow_guarded_delete: bool = False) -> tuple[str, ...]:
    def clause(allowed: bool) -> str:
        if allowed:
            return ("WHEN NOT EXISTS (SELECT 1 FROM _guard "
                    "WHERE key = 'maintenance_unlocked')")
        return ""

    return (
        f"""CREATE TRIGGER {table}_no_update BEFORE UPDATE ON {table}
            {clause(allow_guarded_update)}
            BEGIN SELECT RAISE(ABORT, 'integrity: {table} rows are append-only'); END""",
        f"""CREATE TRIGGER {table}_no_delete BEFORE DELETE ON {table}
            {clause(allow_guarded_delete)}
            BEGIN SELECT RAISE(ABORT, 'integrity: {table} rows may not be deleted'); END""",
    )


MIGRATION_0001 = Migration(
    id=1,
    schema_version="0.1",
    description=(
        "Initial Morningstar schema: append-only event ledger, captures, "
        "annotations, interpretations with revision history, protocol and "
        "schema version registries, visibility overlay, settings."
    ),
    migration_notes="Creates all tables from scratch; no data to migrate.",
    compatibility_notes="First schema version; nothing earlier exists.",
    statements=(
        "CREATE TABLE _guard (key TEXT PRIMARY KEY, value TEXT)",
        "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
        """CREATE TABLE schema_migrations (
            id INTEGER PRIMARY KEY,
            schema_version TEXT NOT NULL UNIQUE,
            applied_at TEXT NOT NULL,
            description TEXT NOT NULL,
            migration_notes TEXT NOT NULL,
            compatibility_notes TEXT NOT NULL
        )""",
        """CREATE TABLE protocol_versions (
            id TEXT PRIMARY KEY,
            version TEXT NOT NULL UNIQUE,
            created_at TEXT NOT NULL,
            change_description TEXT NOT NULL,
            migration_notes TEXT NOT NULL,
            compatibility_notes TEXT NOT NULL
        )""",
        """CREATE TABLE events (
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
        )""",
        """CREATE TABLE captures (
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
        )""",
        # Visibility is a view preference, not evidence: deliberately
        # mutable, kept out of the captures table so evidence rows
        # stay frozen.
        """CREATE TABLE capture_visibility (
            capture_id TEXT PRIMARY KEY REFERENCES captures(id),
            hidden INTEGER NOT NULL DEFAULT 0,
            updated_at TEXT NOT NULL
        )""",
        """CREATE TABLE annotations (
            id TEXT PRIMARY KEY,
            capture_id TEXT NOT NULL REFERENCES captures(id),
            created_at TEXT NOT NULL,
            type TEXT NOT NULL,
            body TEXT NOT NULL,
            integrity_hash TEXT NOT NULL,
            redacted INTEGER NOT NULL DEFAULT 0
        )""",
        """CREATE TABLE interpretations (
            id TEXT PRIMARY KEY,
            created_at TEXT NOT NULL,
            parent_interpretation_id TEXT REFERENCES interpretations(id),
            integrity_hash TEXT NOT NULL
        )""",
        """CREATE TABLE interpretation_revisions (
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
        )""",
        *_immutable("events", allow_guarded_update=True),
        *_immutable("captures", allow_guarded_update=True),
        *_immutable("annotations", allow_guarded_update=True),
        *_immutable("interpretations"),
        *_immutable("interpretation_revisions"),
        *_immutable("schema_migrations"),
        *_immutable("protocol_versions"),
    ),
    protocol=ProtocolRecord(
        version="0.1",
        change_description=(
            "Initial Morningstar capture protocol: four channels "
            "(observation, phenomenology, action, context); interpretation "
            "is a separate layer."
        ),
        migration_notes="Nothing to migrate.",
        compatibility_notes="First protocol version.",
    ),
)

MIGRATION_0002 = Migration(
    id=2,
    schema_version="0.2",
    description=(
        "Adds protocol_version columns to annotations, interpretations, and "
        "interpretation revisions so every stored object records the protocol "
        "it was hashed under."
    ),
    migration_notes=(
        "Additive only. Existing rows keep NULL protocol_version and are "
        "treated as protocol 0.1 (legacy canonicalization) by the integrity "
        "checker. No hashes are recomputed."
    ),
    compatibility_notes=(
        "Objects written under schema/protocol 0.1 remain readable and "
        "verifiable forever using the original serialization."
    ),
    statements=(
        "ALTER TABLE annotations ADD COLUMN protocol_version TEXT",
        "ALTER TABLE interpretations ADD COLUMN protocol_version TEXT",
        "ALTER TABLE interpretation_revisions ADD COLUMN protocol_version TEXT",
    ),
    protocol=ProtocolRecord(
        version="0.2",
        change_description=(
            "Canonical serialization for integrity hashing is now RFC 8785 "
            "(JSON Canonicalization Scheme). The golden vectors in "
            "tests/golden/jcs_vectors.json define the byte-exact contract "
            "any future implementation (e.g. a native Swift port) must "
            "reproduce."
        ),
        migration_notes=(
            "New objects are hashed over JCS bytes. Objects hashed under "
            "protocol 0.1 keep their original hashes and are verified with "
            "the original serialization — re-hashing history would be later "
            "knowledge rewriting earlier evidence."
        ),
        compatibility_notes=(
            "Integrity verification selects the canonicalization by each "
            "object's recorded protocol version. Hash-chain continuity is "
            "unaffected: chains compare stored hash strings."
        ),
    ),
)

MIGRATIONS: tuple[Migration, ...] = (MIGRATION_0001, MIGRATION_0002)
