"""Append-only storage for Morningstar.

The event ledger (``events`` table) is the provenance backbone: every
write appends an event carrying the object content, chained by
previous-hash. Captures, annotations, and interpretations are also
materialized in their own tables for querying, but nothing evidential
is ever updated in place — SQLite triggers (see migrations.py) reject
UPDATE/DELETE on those tables.

The single sanctioned mutation is redaction (the "permanent deletion"
operation). It blanks content in place, marks the affected rows
``redacted``, and appends a ``capture_redacted`` event. Redacted rows
keep their original integrity hash so the chain remains continuous;
the integrity checker reports them as redacted rather than tampered.
This is the documented trade-off between deletion and append-only
provenance.
"""

from __future__ import annotations

import json
import sqlite3
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path

from .canonical import GENESIS_HASH, integrity_hash
from .config import APP_VERSION, PROTOCOL_VERSION
from .migrations import MIGRATIONS, Migration


class MorningstarError(Exception):
    pass


class NotFoundError(MorningstarError):
    pass


class SchemaVersionError(MorningstarError):
    pass


INTERPRETATION_STATUSES = ("active", "superseded", "discarded")
ANNOTATION_TYPES = ("note", "correction", "context")
STATED_CONTEXT_KEYS = ("location", "weather", "sleep_duration", "heart_rate")

REDACTED = "[redacted]"


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="microseconds")


def _new_id() -> str:
    return str(uuid.uuid4())


class Store:
    """One store per data directory. All public methods are safe to
    call from FastAPI's worker threads (single connection + lock)."""

    def __init__(self, data_dir: str | Path):
        self.data_dir = Path(data_dir)
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self.db_path = self.data_dir / "morningstar.db"
        self.conn = sqlite3.connect(self.db_path, check_same_thread=False)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA foreign_keys = ON")
        self._lock = threading.RLock()
        self._migrate()
        self._ensure_device_id()

    def close(self) -> None:
        self.conn.close()

    # ------------------------------------------------------------------
    # migrations / versions

    def _applied_migrations(self) -> list[sqlite3.Row]:
        exists = self.conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='schema_migrations'"
        ).fetchone()
        if not exists:
            return []
        return self.conn.execute(
            "SELECT * FROM schema_migrations ORDER BY id"
        ).fetchall()

    def _migrate(self) -> None:
        with self._lock:
            applied = {row["id"] for row in self._applied_migrations()}
            for migration in MIGRATIONS:
                if migration.id not in applied:
                    self.apply_migration(migration)

    def apply_migration(self, migration: Migration) -> None:
        """Apply a schema migration. Refuses to mutate the schema
        without a strictly increasing id and an unused schema version —
        silent schema mutation is an instrument failure."""
        with self._lock:
            applied = self._applied_migrations()
            last_id = applied[-1]["id"] if applied else 0
            if migration.id != last_id + 1:
                raise SchemaVersionError(
                    f"migration id {migration.id} does not follow {last_id}; "
                    "schema changes must be sequential"
                )
            if any(r["schema_version"] == migration.schema_version for r in applied):
                raise SchemaVersionError(
                    f"schema version {migration.schema_version!r} already registered; "
                    "a schema change requires a new version record"
                )
            with self.conn:
                for stmt in migration.statements:
                    self.conn.execute(stmt)
                self.conn.execute(
                    "INSERT INTO schema_migrations "
                    "(id, schema_version, applied_at, description, migration_notes, compatibility_notes) "
                    "VALUES (?,?,?,?,?,?)",
                    (migration.id, migration.schema_version, utc_now(),
                     migration.description, migration.migration_notes,
                     migration.compatibility_notes),
                )
                if migration.id == 1:
                    self._register_protocol_version(
                        PROTOCOL_VERSION,
                        change_description="Initial Morningstar capture protocol: "
                        "four channels (observation, phenomenology, action, context); "
                        "interpretation is a separate layer.",
                        migration_notes="Nothing to migrate.",
                        compatibility_notes="First protocol version.",
                    )
                self._append_event(
                    "schema_migrated",
                    {
                        "migration_id": migration.id,
                        "schema_version": migration.schema_version,
                        "description": migration.description,
                        "migration_notes": migration.migration_notes,
                        "compatibility_notes": migration.compatibility_notes,
                    },
                    schema_version=migration.schema_version,
                )

    def _register_protocol_version(self, version: str, *, change_description: str,
                                   migration_notes: str, compatibility_notes: str) -> None:
        created = utc_now()
        self.conn.execute(
            "INSERT INTO protocol_versions VALUES (?,?,?,?,?,?)",
            (_new_id(), version, created, change_description,
             migration_notes, compatibility_notes),
        )
        self._append_event(
            "protocol_version_registered",
            {
                "version": version,
                "change_description": change_description,
                "migration_notes": migration_notes,
                "compatibility_notes": compatibility_notes,
            },
            schema_version=MIGRATIONS[0].schema_version,
        )

    @property
    def schema_version(self) -> str:
        row = self.conn.execute(
            "SELECT schema_version FROM schema_migrations ORDER BY id DESC LIMIT 1"
        ).fetchone()
        return row["schema_version"]

    def schema_versions(self) -> list[dict]:
        return [dict(r) for r in self.conn.execute(
            "SELECT * FROM schema_migrations ORDER BY id")]

    def protocol_versions(self) -> list[dict]:
        return [dict(r) for r in self.conn.execute(
            "SELECT * FROM protocol_versions ORDER BY created_at")]

    # ------------------------------------------------------------------
    # settings / device identity

    def get_setting(self, key: str, default: str | None = None) -> str | None:
        row = self.conn.execute(
            "SELECT value FROM settings WHERE key=?", (key,)).fetchone()
        return row["value"] if row else default

    def set_setting(self, key: str, value: str) -> None:
        with self._lock, self.conn:
            self.conn.execute(
                "INSERT INTO settings (key, value) VALUES (?,?) "
                "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                (key, value),
            )

    def _ensure_device_id(self) -> None:
        # A random identifier for this data directory — it identifies
        # the runtime without revealing anything about the device.
        if self.get_setting("device_id") is None:
            self.set_setting("device_id", uuid.uuid4().hex)

    @property
    def device_id(self) -> str:
        return self.get_setting("device_id")

    @property
    def device_metadata_consent(self) -> bool:
        return self.get_setting("device_metadata_consent") == "true"

    def set_device_metadata_consent(self, granted: bool) -> None:
        self.set_setting("device_metadata_consent", "true" if granted else "false")
        with self._lock, self.conn:
            self._append_event(
                "device_metadata_consent_changed", {"granted": granted})

    # ------------------------------------------------------------------
    # event ledger

    def _append_event(self, event_type: str, payload: dict,
                      schema_version: str | None = None) -> dict:
        """Append one event to the ledger. Callers hold the lock and an
        open transaction."""
        last = self.conn.execute(
            "SELECT seq, integrity_hash FROM events ORDER BY seq DESC LIMIT 1"
        ).fetchone()
        seq = (last["seq"] + 1) if last else 1
        previous_hash = last["integrity_hash"] if last else GENESIS_HASH
        content = {
            "id": _new_id(),
            "seq": seq,
            "event_type": event_type,
            "created_at": utc_now(),
            "payload": payload,
            "protocol_version": PROTOCOL_VERSION,
            "schema_version": schema_version or self.schema_version,
            "previous_hash": previous_hash,
        }
        digest = integrity_hash(content)
        self.conn.execute(
            "INSERT INTO events (seq, id, event_type, created_at, payload, "
            "protocol_version, schema_version, integrity_hash, previous_hash) "
            "VALUES (?,?,?,?,?,?,?,?,?)",
            (seq, content["id"], event_type, content["created_at"],
             json.dumps(payload, ensure_ascii=False), content["protocol_version"],
             content["schema_version"], digest, previous_hash),
        )
        return {**content, "integrity_hash": digest}

    def events(self) -> list[dict]:
        rows = self.conn.execute("SELECT * FROM events ORDER BY seq").fetchall()
        out = []
        for r in rows:
            d = dict(r)
            d["payload"] = json.loads(d["payload"])
            out.append(d)
        return out

    def recent_events(self, n: int = 20) -> list[dict]:
        return self.events()[-n:][::-1]

    # ------------------------------------------------------------------
    # captures

    def build_automatic_context(self, capture_source: str) -> dict:
        """Context the instrument collects on its own. Everything here
        is measured or configured, never inferred."""
        local = datetime.now().astimezone()
        last = self.conn.execute(
            "SELECT created_at FROM captures ORDER BY sequence_number DESC LIMIT 1"
        ).fetchone()
        elapsed = None
        if last:
            prev_dt = datetime.fromisoformat(last["created_at"])
            elapsed = int((datetime.now(timezone.utc) - prev_dt).total_seconds())
        ctx = {
            "captured_at_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "captured_at_local": local.isoformat(timespec="seconds"),
            "timezone": str(local.tzinfo),
            "utc_offset_minutes": int(local.utcoffset().total_seconds() // 60),
            "app_version": APP_VERSION,
            "protocol_version": PROTOCOL_VERSION,
            "schema_version": self.schema_version,
            "device_id": self.device_id,
            "capture_source": capture_source,
            "elapsed_since_previous_capture_seconds": elapsed,
        }
        if self.device_metadata_consent:
            import platform
            ctx["platform"] = platform.platform()
            ctx["hostname"] = platform.node()
        return ctx

    def commit_capture(self, *, observation: str = "", phenomenology: str = "",
                       action: str = "", recorded_at: str | None = None,
                       source: str | None = None, recall_latency: str | None = None,
                       stated_context: dict | None = None,
                       capture_source: str = "api") -> dict:
        """Create and commit a capture in one step. The capture is
        immutable from this moment; later material becomes annotations.

        The caller supplies natural text only — ids, sequence numbers,
        hashes, timestamps, and versions are assigned here."""
        stated = {
            k: v for k, v in (stated_context or {}).items()
            if k in STATED_CONTEXT_KEYS and v
        }
        with self._lock, self.conn:
            last = self.conn.execute(
                "SELECT sequence_number, integrity_hash FROM captures "
                "ORDER BY sequence_number DESC LIMIT 1"
            ).fetchone()
            sequence_number = (last["sequence_number"] + 1) if last else 1
            previous_hash = last["integrity_hash"] if last else GENESIS_HASH
            now = utc_now()
            context_snapshot = {
                "automatic": self.build_automatic_context(capture_source),
                "stated": stated,
            }
            content = {
                "id": _new_id(),
                "sequence_number": sequence_number,
                "created_at": now,
                "recorded_at": recorded_at or None,
                "timezone": context_snapshot["automatic"]["timezone"],
                "observation": observation,
                "phenomenology": phenomenology,
                "action": action,
                "source": source or None,
                "recall_latency": recall_latency or None,
                "protocol_version": PROTOCOL_VERSION,
                "schema_version": self.schema_version,
                "context_snapshot": context_snapshot,
                "previous_hash": previous_hash,
                "committed_at": now,
            }
            digest = integrity_hash(content)
            self.conn.execute(
                "INSERT INTO captures (id, sequence_number, created_at, recorded_at, "
                "timezone, observation, phenomenology, action, source, recall_latency, "
                "protocol_version, schema_version, context_snapshot, integrity_hash, "
                "previous_hash, committed_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (content["id"], sequence_number, now, content["recorded_at"],
                 content["timezone"], observation, phenomenology, action,
                 content["source"], content["recall_latency"], PROTOCOL_VERSION,
                 content["schema_version"],
                 json.dumps(context_snapshot, ensure_ascii=False),
                 digest, previous_hash, now),
            )
            self.conn.execute(
                "INSERT INTO capture_visibility (capture_id, hidden, updated_at) "
                "VALUES (?,0,?)", (content["id"], now),
            )
            self._append_event(
                "capture_committed", {**content, "integrity_hash": digest})
            return {**content, "integrity_hash": digest, "hidden": False,
                    "redacted": False}

    def _capture_dict(self, row: sqlite3.Row) -> dict:
        d = dict(row)
        d["context_snapshot"] = json.loads(d["context_snapshot"])
        d["redacted"] = bool(d["redacted"])
        vis = self.conn.execute(
            "SELECT hidden FROM capture_visibility WHERE capture_id=?",
            (d["id"],)).fetchone()
        d["hidden"] = bool(vis["hidden"]) if vis else False
        return d

    def get_capture(self, capture_id: str) -> dict:
        row = self.conn.execute(
            "SELECT * FROM captures WHERE id=?", (capture_id,)).fetchone()
        if not row:
            raise NotFoundError(f"no capture {capture_id}")
        return self._capture_dict(row)

    def list_captures(self, include_hidden: bool = False) -> list[dict]:
        rows = self.conn.execute(
            "SELECT * FROM captures ORDER BY sequence_number").fetchall()
        captures = [self._capture_dict(r) for r in rows]
        if not include_hidden:
            captures = [c for c in captures if not c["hidden"]]
        return captures

    def hide_capture(self, capture_id: str) -> None:
        self._set_hidden(capture_id, True)

    def unhide_capture(self, capture_id: str) -> None:
        self._set_hidden(capture_id, False)

    def _set_hidden(self, capture_id: str, hidden: bool) -> None:
        self.get_capture(capture_id)
        with self._lock, self.conn:
            self.conn.execute(
                "INSERT INTO capture_visibility (capture_id, hidden, updated_at) "
                "VALUES (?,?,?) ON CONFLICT(capture_id) DO UPDATE SET "
                "hidden=excluded.hidden, updated_at=excluded.updated_at",
                (capture_id, int(hidden), utc_now()),
            )
            self._append_event(
                "capture_hidden" if hidden else "capture_unhidden",
                {"capture_id": capture_id},
            )

    def redact_capture(self, capture_id: str) -> None:
        """Permanent deletion of capture content.

        Content is blanked in the capture row, its annotations, and the
        event payloads that carried it. The rows, ordering, original
        integrity hashes, and hash chain remain, so the ledger stays
        continuous but the redacted content is reported as unverifiable
        by the integrity check. This is irreversible."""
        self.get_capture(capture_id)
        with self._lock, self.conn:
            self.conn.execute(
                "INSERT OR REPLACE INTO _guard (key, value) "
                "VALUES ('maintenance_unlocked','1')")
            try:
                self.conn.execute(
                    "UPDATE captures SET observation=?, phenomenology=?, action=?, "
                    "source=NULL, recall_latency=NULL, recorded_at=NULL, "
                    "context_snapshot=?, redacted=1 WHERE id=?",
                    (REDACTED, REDACTED, REDACTED,
                     json.dumps({"redacted": True}), capture_id),
                )
                self.conn.execute(
                    "UPDATE annotations SET body=?, redacted=1 WHERE capture_id=?",
                    (REDACTED, capture_id),
                )
                self.conn.execute(
                    "UPDATE events SET payload=?, redacted=1 WHERE "
                    "json_extract(payload,'$.id')=? OR "
                    "json_extract(payload,'$.capture_id')=?",
                    (json.dumps({"redacted": True, "capture_id": capture_id}),
                     capture_id, capture_id),
                )
            finally:
                self.conn.execute(
                    "DELETE FROM _guard WHERE key='maintenance_unlocked'")
            self._append_event("capture_redacted", {"capture_id": capture_id})

    # ------------------------------------------------------------------
    # annotations

    def annotate(self, capture_id: str, type_: str, body: str) -> dict:
        """Attach later material to a committed capture. This is the
        only way to 'correct' a capture — the original is untouched."""
        if type_ not in ANNOTATION_TYPES:
            type_ = "note"
        self.get_capture(capture_id)
        with self._lock, self.conn:
            content = {
                "id": _new_id(),
                "capture_id": capture_id,
                "created_at": utc_now(),
                "type": type_,
                "body": body,
            }
            digest = integrity_hash(content)
            self.conn.execute(
                "INSERT INTO annotations (id, capture_id, created_at, type, body, "
                "integrity_hash) VALUES (?,?,?,?,?,?)",
                (content["id"], capture_id, content["created_at"], type_, body, digest),
            )
            event_type = ("capture_correction_proposed" if type_ == "correction"
                          else "annotation_added")
            self._append_event(event_type, {**content, "integrity_hash": digest})
            return {**content, "integrity_hash": digest}

    def annotations_for(self, capture_id: str) -> list[dict]:
        rows = self.conn.execute(
            "SELECT * FROM annotations WHERE capture_id=? ORDER BY created_at",
            (capture_id,)).fetchall()
        return [dict(r) for r in rows]

    # ------------------------------------------------------------------
    # interpretations

    def create_interpretation(self, *, title: str, body: str,
                              capture_ids: list[str],
                              parent_interpretation_id: str | None = None,
                              confidence: float | None = None) -> dict:
        for cid in capture_ids:
            self.get_capture(cid)
        if parent_interpretation_id:
            self.get_interpretation(parent_interpretation_id)
        with self._lock, self.conn:
            base = {
                "id": _new_id(),
                "created_at": utc_now(),
                "parent_interpretation_id": parent_interpretation_id,
            }
            base_digest = integrity_hash(base)
            self.conn.execute(
                "INSERT INTO interpretations (id, created_at, "
                "parent_interpretation_id, integrity_hash) VALUES (?,?,?,?)",
                (base["id"], base["created_at"], parent_interpretation_id, base_digest),
            )
            revision = self._add_revision(
                base["id"], revision=1, title=title, body=body,
                capture_ids=capture_ids, status="active", confidence=confidence)
            self._append_event("interpretation_created", {
                **base, "integrity_hash": base_digest, "revision": revision})
            return self.get_interpretation(base["id"])

    def _add_revision(self, interpretation_id: str, *, revision: int, title: str,
                      body: str, capture_ids: list[str], status: str,
                      confidence: float | None) -> dict:
        if status not in INTERPRETATION_STATUSES:
            raise MorningstarError(f"invalid status {status!r}")
        content = {
            "id": _new_id(),
            "interpretation_id": interpretation_id,
            "revision": revision,
            "created_at": utc_now(),
            "title": title,
            "body": body,
            "referenced_capture_ids": list(capture_ids),
            "status": status,
            "confidence": confidence,
        }
        digest = integrity_hash(content)
        self.conn.execute(
            "INSERT INTO interpretation_revisions (id, interpretation_id, revision, "
            "created_at, title, body, referenced_capture_ids, status, confidence, "
            "integrity_hash) VALUES (?,?,?,?,?,?,?,?,?,?)",
            (content["id"], interpretation_id, revision, content["created_at"],
             title, body, json.dumps(list(capture_ids)), status, confidence, digest),
        )
        return {**content, "integrity_hash": digest}

    def revise_interpretation(self, interpretation_id: str, *,
                              title: str | None = None, body: str | None = None,
                              capture_ids: list[str] | None = None,
                              status: str | None = None,
                              confidence: float | None = None) -> dict:
        """Append a new revision; earlier revisions remain on record."""
        current = self.get_interpretation(interpretation_id)
        if capture_ids is not None:
            for cid in capture_ids:
                self.get_capture(cid)
        with self._lock, self.conn:
            revision = self._add_revision(
                interpretation_id,
                revision=current["revision"] + 1,
                title=title if title is not None else current["title"],
                body=body if body is not None else current["body"],
                capture_ids=(capture_ids if capture_ids is not None
                             else current["referenced_capture_ids"]),
                status=status if status is not None else current["status"],
                confidence=(confidence if confidence is not None
                            else current["confidence"]),
            )
            event_type = ("interpretation_status_changed"
                          if status is not None and title is None and body is None
                          else "interpretation_revised")
            self._append_event(event_type, revision)
        return self.get_interpretation(interpretation_id)

    def set_interpretation_status(self, interpretation_id: str, status: str) -> dict:
        return self.revise_interpretation(interpretation_id, status=status)

    def get_interpretation(self, interpretation_id: str) -> dict:
        row = self.conn.execute(
            "SELECT * FROM interpretations WHERE id=?",
            (interpretation_id,)).fetchone()
        if not row:
            raise NotFoundError(f"no interpretation {interpretation_id}")
        revisions = [dict(r) for r in self.conn.execute(
            "SELECT * FROM interpretation_revisions WHERE interpretation_id=? "
            "ORDER BY revision", (interpretation_id,))]
        for rev in revisions:
            rev["referenced_capture_ids"] = json.loads(rev["referenced_capture_ids"])
        current = revisions[-1]
        children = [r["id"] for r in self.conn.execute(
            "SELECT id FROM interpretations WHERE parent_interpretation_id=?",
            (interpretation_id,))]
        return {
            "id": row["id"],
            "created_at": row["created_at"],
            "parent_interpretation_id": row["parent_interpretation_id"],
            "integrity_hash": row["integrity_hash"],
            "title": current["title"],
            "body": current["body"],
            "referenced_capture_ids": current["referenced_capture_ids"],
            "status": current["status"],
            "confidence": current["confidence"],
            "revision": current["revision"],
            "revisions": revisions,
            "child_interpretation_ids": children,
        }

    def list_interpretations(self) -> list[dict]:
        rows = self.conn.execute(
            "SELECT id FROM interpretations ORDER BY created_at").fetchall()
        return [self.get_interpretation(r["id"]) for r in rows]

    def interpretations_for_capture(self, capture_id: str) -> list[dict]:
        return [i for i in self.list_interpretations()
                if capture_id in i["referenced_capture_ids"]]

    # ------------------------------------------------------------------
    # integrity verification

    def verify_integrity(self, now: str | None = None) -> dict:
        """Recheck the whole store: event ordering, hash-chain
        continuity, object hashes, reference integrity, and version
        registration. Redactions and hidden captures are reported as
        warnings — instrument conditions, not user failures."""
        errors: list[str] = []
        warnings: list[str] = []

        events = self.conn.execute("SELECT * FROM events ORDER BY seq").fetchall()
        previous = GENESIS_HASH
        expected_seq = 1
        for ev in events:
            label = f"event {ev['seq']} ({ev['event_type']})"
            if ev["seq"] != expected_seq:
                errors.append(f"{label}: sequence gap (expected {expected_seq})")
                expected_seq = ev["seq"]
            if ev["previous_hash"] != previous:
                errors.append(f"{label}: previous-hash break in event chain")
            if ev["redacted"]:
                warnings.append(f"{label}: payload redacted; "
                                "content hash not verifiable")
            else:
                content = {
                    "id": ev["id"], "seq": ev["seq"],
                    "event_type": ev["event_type"],
                    "created_at": ev["created_at"],
                    "payload": json.loads(ev["payload"]),
                    "protocol_version": ev["protocol_version"],
                    "schema_version": ev["schema_version"],
                    "previous_hash": ev["previous_hash"],
                }
                if integrity_hash(content) != ev["integrity_hash"]:
                    errors.append(f"{label}: stored hash does not match content")
            previous = ev["integrity_hash"]
            expected_seq += 1

        schema_versions = {r["schema_version"] for r in self.schema_versions()}
        protocol_versions = {r["version"] for r in self.protocol_versions()}

        captures = self.conn.execute(
            "SELECT * FROM captures ORDER BY sequence_number").fetchall()
        prev_capture_hash = GENESIS_HASH
        for cap in captures:
            label = f"capture {cap['sequence_number']:03d}"
            if cap["previous_hash"] != prev_capture_hash:
                errors.append(f"{label}: previous-hash break in capture chain")
            prev_capture_hash = cap["integrity_hash"]
            if cap["schema_version"] not in schema_versions:
                errors.append(f"{label}: unregistered schema version "
                              f"{cap['schema_version']!r}")
            if cap["protocol_version"] not in protocol_versions:
                errors.append(f"{label}: unregistered protocol version "
                              f"{cap['protocol_version']!r}")
            if cap["redacted"]:
                warnings.append(f"{label}: content redacted; original hash "
                                "retained but no longer verifiable")
                continue
            content = {
                "id": cap["id"],
                "sequence_number": cap["sequence_number"],
                "created_at": cap["created_at"],
                "recorded_at": cap["recorded_at"],
                "timezone": cap["timezone"],
                "observation": cap["observation"],
                "phenomenology": cap["phenomenology"],
                "action": cap["action"],
                "source": cap["source"],
                "recall_latency": cap["recall_latency"],
                "protocol_version": cap["protocol_version"],
                "schema_version": cap["schema_version"],
                "context_snapshot": json.loads(cap["context_snapshot"]),
                "previous_hash": cap["previous_hash"],
                "committed_at": cap["committed_at"],
            }
            if integrity_hash(content) != cap["integrity_hash"]:
                errors.append(f"{label}: stored hash does not match content "
                              "(possible retrospective edit)")

        capture_ids = {c["id"] for c in captures}
        annotations = self.conn.execute("SELECT * FROM annotations").fetchall()
        for ann in annotations:
            label = f"annotation {ann['id'][:8]}"
            if ann["capture_id"] not in capture_ids:
                errors.append(f"{label}: references missing capture")
            if ann["redacted"]:
                continue
            content = {"id": ann["id"], "capture_id": ann["capture_id"],
                       "created_at": ann["created_at"], "type": ann["type"],
                       "body": ann["body"]}
            if integrity_hash(content) != ann["integrity_hash"]:
                errors.append(f"{label}: stored hash does not match content")

        interp_count = 0
        for interp in self.list_interpretations():
            interp_count += 1
            label = f"interpretation {interp['id'][:8]}"
            for rev in interp["revisions"]:
                content = {
                    "id": rev["id"],
                    "interpretation_id": rev["interpretation_id"],
                    "revision": rev["revision"],
                    "created_at": rev["created_at"],
                    "title": rev["title"], "body": rev["body"],
                    "referenced_capture_ids": rev["referenced_capture_ids"],
                    "status": rev["status"], "confidence": rev["confidence"],
                }
                if integrity_hash(content) != rev["integrity_hash"]:
                    errors.append(f"{label} rev {rev['revision']}: "
                                  "stored hash does not match content")
                for cid in rev["referenced_capture_ids"]:
                    if cid not in capture_ids:
                        errors.append(f"{label} rev {rev['revision']}: "
                                      "references missing capture")

        hidden = self.conn.execute(
            "SELECT COUNT(*) c FROM capture_visibility WHERE hidden=1").fetchone()["c"]
        if hidden:
            warnings.append(f"{hidden} capture(s) hidden from normal view "
                            "(evidence retained)")

        return {
            "ok": not errors,
            "checked_at": now or utc_now(),
            "errors": errors,
            "warnings": warnings,
            "counts": {
                "events": len(events),
                "captures": len(captures),
                "annotations": len(annotations),
                "interpretations": interp_count,
                "schema_versions": len(schema_versions),
                "protocol_versions": len(protocol_versions),
            },
        }
