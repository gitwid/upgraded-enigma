"""Store-level tests for the append-only domain model."""

import sqlite3

import pytest

from morningstar.migrations import Migration
from morningstar.store import SchemaVersionError, Store


def commit(store: Store, **kwargs) -> dict:
    defaults = dict(
        observation="meeting ended 14:17",
        phenomenology="relief",
        action="closed laptop",
    )
    defaults.update(kwargs)
    return store.commit_capture(**defaults)


# 1. A committed capture cannot be modified.
def test_committed_capture_cannot_be_modified(store):
    cap = commit(store)
    with pytest.raises(sqlite3.DatabaseError, match="append-only"):
        with store.conn:
            store.conn.execute(
                "UPDATE captures SET observation='rewritten history' WHERE id=?",
                (cap["id"],))
    with pytest.raises(sqlite3.DatabaseError, match="may not be deleted"):
        with store.conn:
            store.conn.execute("DELETE FROM captures WHERE id=?", (cap["id"],))
    # The store exposes no update API for captures at all.
    assert not any("update_capture" in name or "edit_capture" in name
                   for name in dir(store))
    assert store.get_capture(cap["id"])["observation"] == "meeting ended 14:17"


# 2. A correction creates an annotation.
def test_correction_creates_annotation(store):
    cap = commit(store)
    ann = store.annotate(cap["id"], "correction",
                         "the meeting actually ended 14:19")
    assert ann["type"] == "correction"
    annotations = store.annotations_for(cap["id"])
    assert [a["id"] for a in annotations] == [ann["id"]]
    # Original capture is byte-identical.
    after = store.get_capture(cap["id"])
    assert after["observation"] == cap["observation"]
    assert after["integrity_hash"] == cap["integrity_hash"]
    # And the correction is on the ledger as its own event.
    assert any(e["event_type"] == "capture_correction_proposed"
               for e in store.events())


# 3. Interpretations reference captures without altering them.
def test_interpretation_references_without_altering(store):
    cap = commit(store)
    before = store.get_capture(cap["id"])
    interp = store.create_interpretation(
        title="Possible avoidance pattern", body="Maybe I withdraw when…",
        capture_ids=[cap["id"]])
    assert cap["id"] in interp["referenced_capture_ids"]
    after = store.get_capture(cap["id"])
    assert after == before
    assert store.verify_integrity()["ok"]


# 4. Competing interpretations can coexist.
def test_competing_interpretations_coexist(store):
    cap = commit(store)
    a = store.create_interpretation(
        title="Reading A", body="It meant X.", capture_ids=[cap["id"]])
    b = store.create_interpretation(
        title="Reading B", body="It meant not-X.", capture_ids=[cap["id"]])
    both = store.interpretations_for_capture(cap["id"])
    assert {i["id"] for i in both} == {a["id"], b["id"]}
    assert all(i["status"] == "active" for i in both)


# 5. Schema changes require a new version record.
def test_schema_change_requires_new_version_record(store):
    with pytest.raises(SchemaVersionError, match="new version record"):
        store.apply_migration(Migration(
            id=2, schema_version="0.1",  # reuses the registered version
            description="sneaky mutation", migration_notes="",
            compatibility_notes="",
            statements=("ALTER TABLE captures ADD COLUMN sneaky TEXT",)))
    with pytest.raises(SchemaVersionError, match="sequential"):
        store.apply_migration(Migration(
            id=5, schema_version="0.5", description="skips ahead",
            migration_notes="", compatibility_notes="", statements=()))
    store.apply_migration(Migration(
        id=2, schema_version="0.1.1", description="adds an optional column",
        migration_notes="none", compatibility_notes="additive only",
        statements=("ALTER TABLE captures ADD COLUMN extra TEXT",)))
    assert store.schema_version == "0.1.1"
    assert [m["schema_version"] for m in store.schema_versions()] == ["0.1", "0.1.1"]
    assert any(e["event_type"] == "schema_migrated"
               and e["payload"]["schema_version"] == "0.1.1"
               for e in store.events())


# 7. Hash verification detects tampering.
def test_hash_verification_detects_tampering(store):
    cap = commit(store)
    assert store.verify_integrity()["ok"]
    # Tamper by bypassing the trigger guard, as an attacker with DB access could.
    with store.conn:
        store.conn.execute(
            "INSERT INTO _guard VALUES ('maintenance_unlocked','1')")
        store.conn.execute(
            "UPDATE captures SET observation='it never happened' WHERE id=?",
            (cap["id"],))
        store.conn.execute("DELETE FROM _guard")
    report = store.verify_integrity()
    assert not report["ok"]
    assert any("does not match" in e for e in report["errors"])


# 8. Optional metadata may be absent.
def test_optional_metadata_may_be_absent(store):
    cap = store.commit_capture(observation="door closed")
    assert cap["source"] is None
    assert cap["recall_latency"] is None
    assert cap["recorded_at"] is None
    assert cap["context_snapshot"]["stated"] == {}
    assert store.verify_integrity()["ok"]


# 10. Sequence numbers are assigned automatically.
def test_sequence_numbers_assigned_automatically(store):
    caps = [commit(store) for _ in range(3)]
    assert [c["sequence_number"] for c in caps] == [1, 2, 3]
    # ...and chained: each capture references its predecessor's hash.
    assert caps[1]["previous_hash"] == caps[0]["integrity_hash"]
    assert caps[2]["previous_hash"] == caps[1]["integrity_hash"]


# 12. Historical captures remain readable after a schema migration.
def test_historical_captures_readable_after_migration(store):
    old = commit(store, observation="written under schema 0.1")
    store.apply_migration(Migration(
        id=2, schema_version="0.2", description="adds optional mood column",
        migration_notes="additive; old rows keep NULL",
        compatibility_notes="captures recorded under 0.1 stay valid",
        statements=("ALTER TABLE captures ADD COLUMN mood TEXT",)))
    readback = store.get_capture(old["id"])
    assert readback["observation"] == "written under schema 0.1"
    assert readback["schema_version"] == "0.1"
    new = commit(store, observation="written under schema 0.2")
    assert new["schema_version"] == "0.2"
    report = store.verify_integrity()
    assert report["ok"], report["errors"]


def test_event_chain_and_context_automation(store):
    commit(store)
    commit(store)
    events = store.events()
    assert [e["seq"] for e in events] == list(range(1, len(events) + 1))
    ctx = store.get_capture(store.list_captures()[1]["id"])["context_snapshot"]
    auto = ctx["automatic"]
    assert auto["elapsed_since_previous_capture_seconds"] is not None
    assert auto["timezone"]
    assert auto["device_id"] == store.device_id
    # No device platform data without explicit consent.
    assert "platform" not in auto and "hostname" not in auto


def test_hide_and_redact(store):
    cap = commit(store, observation="sensitive content")
    store.hide_capture(cap["id"])
    assert store.list_captures() == []
    assert len(store.list_captures(include_hidden=True)) == 1
    store.unhide_capture(cap["id"])
    assert len(store.list_captures()) == 1

    store.annotate(cap["id"], "note", "also sensitive")
    store.redact_capture(cap["id"])
    after = store.get_capture(cap["id"])
    assert after["redacted"] and after["observation"] == "[redacted]"
    assert store.annotations_for(cap["id"])[0]["body"] == "[redacted]"
    # Content is gone from the ledger too.
    dump = " ".join(str(e["payload"]) for e in store.events())
    assert "sensitive content" not in dump and "also sensitive" not in dump
    # Redaction is reported as a warning, not tampering.
    report = store.verify_integrity()
    assert report["ok"], report["errors"]
    assert any("redacted" in w for w in report["warnings"])


def test_interpretation_revision_branch_supersede(store):
    cap = commit(store)
    interp = store.create_interpretation(
        title="First reading", body="v1", capture_ids=[cap["id"]],
        confidence=0.4)
    revised = store.revise_interpretation(interp["id"], body="v2",
                                          confidence=0.6)
    assert revised["revision"] == 2 and revised["body"] == "v2"
    assert [r["body"] for r in revised["revisions"]] == ["v1", "v2"]

    branch = store.create_interpretation(
        title="Alternative reading", body="other take",
        capture_ids=[cap["id"]], parent_interpretation_id=interp["id"])
    assert branch["parent_interpretation_id"] == interp["id"]
    superseded = store.set_interpretation_status(interp["id"], "superseded")
    assert superseded["status"] == "superseded"
    # History of the superseded interpretation is intact.
    assert [r["revision"] for r in superseded["revisions"]] == [1, 2, 3]
