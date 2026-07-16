"""Protocol 0.2: mixed-era stores verify correctly.

A store that lived through the 0.1 → 0.2 transition holds objects hashed
under two different canonicalizations. Verification must pick the right
one per object — and old evidence is never re-hashed."""

import json

from morningstar.canonical import GENESIS_HASH, legacy_integrity_hash
from morningstar.store import utc_now


def test_fresh_store_registers_both_versions(store):
    assert [p["version"] for p in store.protocol_versions()] == ["0.1", "0.2"]
    assert [s["schema_version"] for s in store.schema_versions()] == ["0.1", "0.2"]
    assert store.schema_version == "0.2"
    events = store.events()
    registered = [e["payload"]["version"] for e in events
                  if e["event_type"] == "protocol_version_registered"]
    assert registered == ["0.1", "0.2"]


def test_new_objects_carry_protocol_02_and_verify(store):
    cap = store.commit_capture(observation="door closed", phenomenology="calm",
                               action="locked up")
    assert cap["protocol_version"] == "0.2"
    ann = store.annotate(cap["id"], "note", "later thought")
    interp = store.create_interpretation(title="Reading", body="maybe",
                                         capture_ids=[cap["id"]], confidence=1.0)
    assert interp["protocol_version"] == "0.2"
    # confidence 1.0 canonicalizes as "1" under JCS vs "1.0" legacy — the
    # exact divergence that motivated pinning the serialization.
    report = store.verify_integrity()
    assert report["ok"], report["errors"]


def test_v01_era_rows_still_verify(store):
    # Simulate a capture committed by the 0.1 instrument: legacy hash,
    # protocol_version 0.1, inserted as an upgraded database would hold it.
    now = utc_now()
    content = {
        "id": "00000000-0000-4000-8000-00000000ab01",
        "sequence_number": 1,
        "created_at": now,
        "recorded_at": "~11:30 CEST",
        "timezone": "CEST",
        "observation": "meeting ended 14:17",
        "phenomenology": "relief",
        "action": "closed laptop",
        "source": None,
        "recall_latency": None,
        "protocol_version": "0.1",
        "schema_version": "0.1",
        "context_snapshot": {"automatic": {}, "stated": {}},
        "previous_hash": GENESIS_HASH,
        "committed_at": now,
    }
    digest = legacy_integrity_hash(content)
    with store.conn:
        store.conn.execute(
            "INSERT INTO captures (id, sequence_number, created_at, recorded_at, "
            "timezone, observation, phenomenology, action, source, recall_latency, "
            "protocol_version, schema_version, context_snapshot, integrity_hash, "
            "previous_hash, committed_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (content["id"], 1, now, content["recorded_at"], "CEST",
             content["observation"], content["phenomenology"], content["action"],
             None, None, "0.1", "0.1", json.dumps(content["context_snapshot"]),
             digest, GENESIS_HASH, now),
        )
        store.conn.execute(
            "INSERT INTO capture_visibility VALUES (?,0,?)", (content["id"], now))
        # legacy annotation: no protocol stamp (NULL), legacy hash
        ann = {"id": "00000000-0000-4000-8000-00000000ab02",
               "capture_id": content["id"], "created_at": now,
               "type": "note", "body": "written under 0.1"}
        store.conn.execute(
            "INSERT INTO annotations (id, capture_id, created_at, type, body, "
            "integrity_hash) VALUES (?,?,?,?,?,?)",
            (ann["id"], ann["capture_id"], now, "note", ann["body"],
             legacy_integrity_hash(ann)),
        )

    report = store.verify_integrity()
    assert report["ok"], report["errors"]

    # A 0.2 capture chains onto the 0.1 capture without friction...
    new = store.commit_capture(observation="written under 0.2")
    assert new["previous_hash"] == digest
    assert store.verify_integrity()["ok"]

    # ...and tampering with the 0.1-era row is still detected.
    with store.conn:
        store.conn.execute("INSERT INTO _guard VALUES ('maintenance_unlocked','1')")
        store.conn.execute(
            "UPDATE captures SET observation='rewritten' WHERE id=?",
            (content["id"],))
        store.conn.execute("DELETE FROM _guard")
    report = store.verify_integrity()
    assert not report["ok"]
    assert any("capture 001" in e for e in report["errors"])
