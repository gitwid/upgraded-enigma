"""Canonical serialization and integrity hashing.

Hashes are SHA-256 over canonical JSON (sorted keys, no whitespace,
unicode preserved). This provides tamper *evidence* for the local
store, not cryptographic proof against an adversary who controls the
machine — see the README's honesty note.
"""

import hashlib
import json

GENESIS_HASH = "0" * 64


def canonical_json(obj) -> str:
    return json.dumps(obj, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


def integrity_hash(obj) -> str:
    return hashlib.sha256(canonical_json(obj).encode("utf-8")).hexdigest()
