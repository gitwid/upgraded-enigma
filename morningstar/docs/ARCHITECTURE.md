# Morningstar v0.1 — architecture note

## Governing rule

The instrument may be structurally rigorous without making the operator
perform that rigor manually. Users type natural text into three boxes;
ids, sequence numbers, timestamps, hashes, versions, and cross-references
are assigned by the software.

## Stack

- Python 3.12, FastAPI + Jinja2, server-rendered HTML (no JS build, no
  frontend framework)
- SQLite via the stdlib `sqlite3` module
- pytest (+ httpx TestClient) for tests

Two deliberate departures from the suggested defaults:

1. **No ORM (SQLModel/SQLAlchemy).** The domain is append-only: rows are
   inserted, never updated. An ORM's main machinery (identity map, dirty
   tracking, update generation) is exactly what this design must *prevent*.
   Plain SQL keeps the storage layer inspectable end to end.
2. **No Alembic.** Migrations are small Python data objects
   (`migrations.py`) carrying the metadata the protocol requires
   (description, migration notes, compatibility notes). Applying one writes
   a `schema_migrations` row **and** appends a `schema_migrated` event —
   schema changes are first-class, observable events, which Alembic's
   out-of-band version table would not give us. A migration reusing an
   already-registered schema version, or skipping a sequence number, is
   rejected (`SchemaVersionError`): schema mutation without a version
   increment is an instrument failure by definition.

## Data model

The **event ledger** (`events`) is the provenance backbone. Every write —
capture committed, annotation added, interpretation created/revised,
consent changed, schema migrated, capture hidden/redacted — appends one
event with: uuid, monotonic `seq`, timestamp, JSON payload, protocol and
schema version, `integrity_hash`, and `previous_hash` (the prior event's
hash; genesis is 64 zeros).

Domain objects are *also* materialized in their own tables for querying:

- `captures` — id, sequence number, created/recorded/committed timestamps,
  timezone, the three channels, source, recall latency, versions,
  `context_snapshot` (JSON: `automatic` vs `stated` sub-objects, so
  measured metadata is never conflated with user statements), integrity
  hash, previous capture's hash.
- `annotations` — reference a capture; types `note` / `correction` /
  `context`. A correction appends a `capture_correction_proposed` event and
  never touches the original.
- `interpretations` + `interpretation_revisions` — the base row is
  immutable identity; every state (title, body, referenced capture ids,
  status, confidence) is an append-only revision. "Editing" an
  interpretation appends revision *n+1*; the history stays. Branching sets
  `parent_interpretation_id` on a new interpretation. Statuses: active /
  superseded / discarded. Competing active interpretations are a supported
  state, not a conflict.
- `protocol_versions`, `schema_migrations` — version registries; every
  capture references the exact versions active at commit time, and old
  captures keep their original schema version forever.
- `capture_visibility` — deliberately mutable overlay (hidden yes/no).
  Visibility is a view preference, not evidence, so it lives outside the
  evidence tables.

`recorded_at` is stored **verbatim as the user said it** ("~11:30 CEST",
"this morning"). Forcing timestamp formats onto humans converts uncertainty
into false precision; the machine timestamp (`created_at`) is captured
separately and automatically.

## Immutability enforcement

Three layers, weakest to strongest claim:

1. The store exposes no update/edit API for evidential objects.
2. SQLite triggers reject `UPDATE`/`DELETE` on `events`, `captures`,
   `annotations`, `interpretations`, `interpretation_revisions`,
   `schema_migrations`, and `protocol_versions` — even hand-written SQL
   against the file fails.
3. Hash verification: canonical JSON (sorted keys, no whitespace) →
   SHA-256 per object, plus previous-hash chaining on events and captures.
   The audit screen re-verifies order, chain continuity, object hashes,
   reference integrity, and version registration on demand.

We claim tamper *evidence*, not tamper *proof*: an adversary with full file
access can rewrite the whole chain. The UI says so.

## Redaction (the sanctioned exception)

Permanent deletion conflicts with append-only provenance; v0.1 resolves it
explicitly rather than pretending otherwise. The triggers honor a
maintenance latch (`_guard` table) that only the redaction code path sets,
inside a single transaction. Redaction blanks content in the capture row,
its annotations, and the event payloads that carried it; marks them
`redacted`; keeps rows, ordering, and original hashes (so the chain stays
continuous); and appends a `capture_redacted` event. The integrity checker
reports redacted objects as warnings ("content no longer verifiable"), not
errors. Hide-from-view is offered first and preferred.

## Leakage assistance

`leakage.py` is a small regex rule table, per channel: causal "because",
motive claims about others, diagnostic/personality labels, predictions,
moral "should", "made me", inferred meaning. Rules are scoped so natural
phenomenology is not policed — "feeling rejected" or "depressed" as felt
experience never flags in the phenomenology channel. Warnings explain the
layer concern, offer (not command) a move to interpretation, never rewrite
text, and never block commit. False positives are accepted by design.

## Unresolved trade-offs

- **Redaction weakens the ledger** for the affected entries; verifiability
  and the right to destroy sensitive content cannot both be total. v0.1
  favors the user's control and reports the loss honestly.
- **No database encryption** in v0.1; the mitigation is OS-level disk
  encryption. SQLCipher would be the natural upgrade path.
- **Draft captures are not persisted** — a browser crash before commit
  loses the draft. This keeps "nothing exists until committed" simple, at
  some capture-burden risk for long entries.
- **Audience-effect drift** (writing for the record instead of accurately)
  is named as a failure mode but not detected in v0.1; only the capture
  source and latency metadata that would let a later analysis look for it
  are recorded.
- **Single-process assumption**: one local server, one SQLite connection
  guarded by a lock. Fine for the intended single-operator use; concurrent
  writers would need WAL mode and per-request connections.
