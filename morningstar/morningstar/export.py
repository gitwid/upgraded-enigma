"""Exports: plain text, Markdown, JSON.

All three preserve original capture text, timestamps, provenance,
schema versions, annotations, interpretation references, and integrity
data. Output ordering is deterministic (ledger order); pass ``now`` to
pin the export timestamp for byte-identical output.
"""

from __future__ import annotations

import json

from .config import APP_VERSION
from .store import Store, utc_now


def snapshot(store: Store, now: str | None = None) -> dict:
    """Complete archive of the store as plain data."""
    captures = []
    for cap in store.list_captures(include_hidden=True):
        cap = dict(cap)
        cap["annotations"] = store.annotations_for(cap["id"])
        cap["referenced_by_interpretation_ids"] = [
            i["id"] for i in store.interpretations_for_capture(cap["id"])]
        captures.append(cap)
    return {
        "format": "morningstar-archive",
        "format_version": "1",
        "app_version": APP_VERSION,
        "exported_at": now or utc_now(),
        "protocol_versions": store.protocol_versions(),
        "schema_versions": store.schema_versions(),
        "captures": captures,
        "interpretations": store.list_interpretations(),
        "events": store.events(),
    }


def export_json(store: Store, now: str | None = None) -> str:
    return json.dumps(snapshot(store, now), indent=2, ensure_ascii=False,
                      sort_keys=True) + "\n"


def _context_lines(cap: dict) -> list[str]:
    lines = []
    auto = cap["context_snapshot"].get("automatic", {})
    stated = cap["context_snapshot"].get("stated", {})
    for key, value in auto.items():
        if value is not None:
            lines.append(f"{key.replace('_', ' ')}: {value}  (collected automatically)")
    for key, value in stated.items():
        lines.append(f"{key.replace('_', ' ')}: {value}  (stated by user)")
    return lines


def _capture_text(cap: dict) -> str:
    def section(title: str, body: str) -> str:
        return f"{title}\n{'-' * len(title)}\n{body.strip() or '(empty)'}"

    header = [
        f"MORNINGSTAR — capture {cap['sequence_number']:03d}",
        f"schema: v{cap['schema_version']}",
        f"protocol: v{cap['protocol_version']}",
        f"recorded: {cap['recorded_at'] or cap['created_at'] + ' (machine timestamp)'}",
        f"committed: {cap['committed_at']}",
        f"source: {cap['source'] or 'not stated'}",
        f"recall latency: {cap['recall_latency'] or 'not stated'}",
    ]
    if cap.get("redacted"):
        header.append("NOTE: this capture was permanently redacted by the user")
    if cap.get("hidden"):
        header.append("NOTE: this capture is hidden from normal view")

    parts = [
        "\n".join(header),
        section("OBSERVATION", cap["observation"]),
        section("PHENOMENOLOGY", cap["phenomenology"]),
        section("ACTION", cap["action"]),
        section("CONTEXT", "\n".join(_context_lines(cap)) or "(redacted)"),
    ]
    if cap.get("annotations"):
        rows = [f"[{a['type']}] {a['created_at']}\n{a['body']}"
                for a in cap["annotations"]]
        parts.append(section("ANNOTATIONS", "\n\n".join(rows)))
    if cap.get("referenced_by"):
        rows = [f"- {i['title']} ({i['status']})" for i in cap["referenced_by"]]
        parts.append(section("REFERENCED BY INTERPRETATIONS", "\n".join(rows)))
    provenance = "\n".join([
        f"id: {cap['id']}",
        f"integrity hash: {cap['integrity_hash']}",
        f"previous hash: {cap['previous_hash']}",
    ])
    parts.append(section("PROVENANCE", provenance))
    return "\n\n".join(parts)


def _gather(store: Store) -> list[dict]:
    captures = []
    for cap in store.list_captures(include_hidden=True):
        cap = dict(cap)
        cap["annotations"] = store.annotations_for(cap["id"])
        cap["referenced_by"] = store.interpretations_for_capture(cap["id"])
        captures.append(cap)
    return captures


def _interpretation_text(interp: dict, store: Store) -> str:
    seqs = []
    for cid in interp["referenced_capture_ids"]:
        cap = store.get_capture(cid)
        seqs.append(f"capture {cap['sequence_number']:03d}")
    lines = [
        f"INTERPRETATION — {interp['title']}",
        f"status: {interp['status']}"
        + (f"  confidence: {interp['confidence']}" if interp["confidence"] is not None else ""),
        f"created: {interp['created_at']}  revision: {interp['revision']}",
        f"references: {', '.join(seqs) or '(none)'}",
    ]
    if interp["parent_interpretation_id"]:
        lines.append(f"branched from: {interp['parent_interpretation_id']}")
    lines += ["", interp["body"].strip(), "",
              f"id: {interp['id']}",
              f"integrity hash: {interp['revisions'][-1]['integrity_hash']}"]
    return "\n".join(lines)


def export_text(store: Store, now: str | None = None) -> str:
    integrity = store.verify_integrity(now=now or utc_now())
    head = [
        "MORNINGSTAR ARCHIVE",
        f"exported: {now or utc_now()}",
        f"app version: {APP_VERSION}",
        f"integrity check: {'passed' if integrity['ok'] else 'FAILED'}",
    ]
    head += [f"  warning: {w}" for w in integrity["warnings"]]
    head += [f"  error: {e}" for e in integrity["errors"]]

    divider = "\n\n" + "=" * 64 + "\n\n"
    blocks = [_capture_text(c) for c in _gather(store)]
    interps = [_interpretation_text(i, store) for i in store.list_interpretations()]
    body = divider.join(blocks + interps) if (blocks or interps) else "(no captures yet)"
    return "\n".join(head) + divider + body + "\n"


def export_markdown(store: Store, now: str | None = None) -> str:
    integrity = store.verify_integrity(now=now or utc_now())
    out = [
        "# Morningstar archive",
        "",
        f"- exported: {now or utc_now()}",
        f"- app version: {APP_VERSION}",
        f"- integrity check: {'passed' if integrity['ok'] else '**FAILED**'}",
    ]
    out += [f"- warning: {w}" for w in integrity["warnings"]]
    out += [f"- error: {e}" for e in integrity["errors"]]
    for cap in _gather(store):
        out += ["", f"## Capture {cap['sequence_number']:03d}", ""]
        out += [
            f"- schema: v{cap['schema_version']} / protocol: v{cap['protocol_version']}",
            f"- recorded: {cap['recorded_at'] or cap['created_at'] + ' (machine timestamp)'}",
            f"- committed: {cap['committed_at']}",
            f"- source: {cap['source'] or 'not stated'}",
            f"- recall latency: {cap['recall_latency'] or 'not stated'}",
        ]
        if cap.get("redacted"):
            out.append("- **permanently redacted by the user**")
        for title, key in (("Observation", "observation"),
                           ("Phenomenology", "phenomenology"),
                           ("Action", "action")):
            out += ["", f"### {title}", "", cap[key].strip() or "*(empty)*"]
        out += ["", "### Context", ""]
        out += [f"- {line}" for line in _context_lines(cap)] or ["*(redacted)*"]
        if cap["annotations"]:
            out += ["", "### Annotations", ""]
            for a in cap["annotations"]:
                out.append(f"- **{a['type']}** ({a['created_at']}): {a['body']}")
        if cap["referenced_by"]:
            out += ["", "### Referenced by interpretations", ""]
            out += [f"- {i['title']} ({i['status']})" for i in cap["referenced_by"]]
        out += ["", "### Provenance", "",
                f"- id: `{cap['id']}`",
                f"- integrity hash: `{cap['integrity_hash']}`",
                f"- previous hash: `{cap['previous_hash']}`"]
    interps = store.list_interpretations()
    if interps:
        out += ["", "## Interpretations"]
        for i in interps:
            out += ["", f"### {i['title']}", "",
                    f"- status: {i['status']}, revision: {i['revision']}",
                    f"- created: {i['created_at']}"]
            if i["confidence"] is not None:
                out.append(f"- confidence: {i['confidence']}")
            if i["parent_interpretation_id"]:
                out.append(f"- branched from: `{i['parent_interpretation_id']}`")
            out += [f"- references: "
                    + (", ".join(f"capture {store.get_capture(c)['sequence_number']:03d}"
                                 for c in i["referenced_capture_ids"]) or "(none)"),
                    "", i["body"].strip()]
    return "\n".join(out) + "\n"
