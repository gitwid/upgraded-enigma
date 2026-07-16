"""Export tests: evidence preservation and determinism."""

import json

from morningstar.export import export_json, export_markdown, export_text

VERBATIM = '08:47 rcvd: "Very unlikely. Tooooo much else going on today and tomorrow"'


def populated(store):
    cap = store.commit_capture(
        observation=VERBATIM + "\n09:48 sent: closure message",
        phenomenology="@08:47: disappointment. feeling rejection.\n@09:48: surrender. fin de partie.",
        action="Ended exchange with closure message (09:48).\nTook out trash.",
        recorded_at="2026-07-16, ~11:30 CEST",
        source="WhatsApp screenshot (verbatim) + prompted recall @ ~2h latency",
        recall_latency="~2h",
    )
    store.annotate(cap["id"], "note", "later thought: unicode check — émotions ✓")
    store.create_interpretation(title="A reading", body="perhaps…",
                                capture_ids=[cap["id"]])
    return cap


# 6. Exports preserve original evidence.
def test_exports_preserve_original_evidence(store):
    cap = populated(store)

    text = export_text(store)
    md = export_markdown(store)
    data = json.loads(export_json(store))

    for out in (text, md):
        assert VERBATIM in out
        assert "fin de partie" in out
        assert "2026-07-16, ~11:30 CEST" in out
        assert cap["integrity_hash"] in out
        assert "émotions ✓" in out          # annotations included
        assert "A reading" in out            # interpretation references

    exported_cap = data["captures"][0]
    assert exported_cap["observation"] == cap["observation"]
    assert exported_cap["created_at"] == cap["created_at"]
    assert exported_cap["schema_version"] == "0.1"
    assert exported_cap["integrity_hash"] == cap["integrity_hash"]
    assert exported_cap["previous_hash"] == cap["previous_hash"]
    assert exported_cap["annotations"][0]["body"].startswith("later thought")
    assert exported_cap["referenced_by_interpretation_ids"]
    assert data["events"]  # full ledger included
    assert data["schema_versions"] and data["protocol_versions"]


def test_export_is_deterministic(store):
    populated(store)
    pinned = "2026-07-16T12:00:00+00:00"
    assert export_json(store, now=pinned) == export_json(store, now=pinned)
    assert export_text(store, now=pinned) == export_text(store, now=pinned)
    assert export_markdown(store, now=pinned) == export_markdown(store, now=pinned)


def test_text_export_readable_without_data_model(store):
    populated(store)
    text = export_text(store)
    # Section headers a human can navigate by, no JSON or SQL required.
    for heading in ("MORNINGSTAR — capture 001", "OBSERVATION",
                    "PHENOMENOLOGY", "ACTION", "CONTEXT", "PROVENANCE"):
        assert heading in text
