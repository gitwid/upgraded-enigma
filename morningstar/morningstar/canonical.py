"""Canonical serialization and integrity hashing.

Protocol 0.1 hashed objects over Python's ``json.dumps(sort_keys=True,
ensure_ascii=False, separators=(",", ":"))`` — deterministic, but defined
by CPython's behavior rather than by a specification another
implementation could be held to.

Protocol 0.2 adopts RFC 8785 (JSON Canonicalization Scheme, JCS), so the
byte stream under every hash is specified independently of language:
UTF-8 output, object keys sorted by UTF-16 code units, minimal string
escaping, ECMAScript number formatting, and no NaN/Infinity. The golden
vectors in ``tests/golden/jcs_vectors.json`` are the executable contract
that any other implementation (e.g. a native Swift port) must reproduce
byte-for-byte before it may claim to verify this store.

Objects hashed under protocol 0.1 are verified with the frozen legacy
serialization forever; nothing is ever re-hashed — that would be later
knowledge rewriting earlier evidence.

Hashes provide tamper *evidence* for the local store, not cryptographic
proof against an adversary who controls the machine.
"""

import hashlib
import json
import math

GENESIS_HASH = "0" * 64

# Numbers must fit IEEE-754 double interchange (RFC 8785 / I-JSON).
_MAX_SAFE_INT = 2**53 - 1


# ---------------------------------------------------------------------------
# legacy (protocol 0.1) — frozen, never change this

def legacy_canonical_json(obj) -> str:
    return json.dumps(obj, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


def legacy_integrity_hash(obj) -> str:
    return hashlib.sha256(legacy_canonical_json(obj).encode("utf-8")).hexdigest()


# ---------------------------------------------------------------------------
# RFC 8785 (protocol 0.2+)

def _es6_number(x: float) -> str:
    """ECMAScript Number::toString for a finite double (ES2015 §7.1.12.1),
    which RFC 8785 mandates for JSON numbers."""
    if math.isnan(x) or math.isinf(x):
        raise ValueError("NaN and Infinity cannot be canonicalized (RFC 8785)")
    if x == 0:
        return "0"  # covers -0.0: ES6 String(-0) is "0"
    sign = "-" if x < 0 else ""
    r = repr(abs(x))  # CPython: shortest decimal that round-trips, like ES6
    if "e" in r:
        mantissa, _, e = r.partition("e")
        exp = int(e)
    else:
        mantissa, exp = r, 0
    int_part, _, frac = mantissa.partition(".")
    digits_all = int_part + frac
    stripped = digits_all.lstrip("0")
    leading = len(digits_all) - len(stripped)
    s = stripped.rstrip("0")
    n = len(s)
    # value = s * 10^(k-n); k = decimal-point position in significant digits
    k = len(int_part) - leading + exp
    if n <= k <= 21:
        body = s + "0" * (k - n)
    elif 0 < k <= 21:
        body = s[:k] + "." + s[k:]
    elif -6 < k <= 0:
        body = "0." + "0" * (-k) + s
    else:
        e10 = k - 1
        mant = s[0] + ("." + s[1:] if n > 1 else "")
        body = f"{mant}e{'+' if e10 >= 0 else '-'}{abs(e10)}"
    return sign + body


def _jcs(value, out: list) -> None:
    if value is None:
        out.append("null")
    elif value is True:
        out.append("true")
    elif value is False:
        out.append("false")
    elif isinstance(value, str):
        # Python's escaping with ensure_ascii=False matches RFC 8785 §3.2.2.2:
        # only " \ and controls < 0x20 escaped; \b \t \n \f \r short forms;
        # remaining controls as lowercase \u00xx; everything else literal.
        out.append(json.dumps(value, ensure_ascii=False))
    elif isinstance(value, int):
        if abs(value) > _MAX_SAFE_INT:
            raise ValueError(f"integer {value} exceeds IEEE-754 double "
                             "interchange range (RFC 8785 / I-JSON)")
        out.append(str(value))
    elif isinstance(value, float):
        out.append(_es6_number(value))
    elif isinstance(value, (list, tuple)):
        out.append("[")
        for i, item in enumerate(value):
            if i:
                out.append(",")
            _jcs(item, out)
        out.append("]")
    elif isinstance(value, dict):
        out.append("{")
        # RFC 8785 sorts keys by UTF-16 code units; comparing UTF-16BE bytes
        # is equivalent (and differs from code-point order for non-BMP keys).
        for i, key in enumerate(sorted(value, key=lambda k: k.encode("utf-16-be"))):
            if not isinstance(key, str):
                raise TypeError("object keys must be strings")
            if i:
                out.append(",")
            out.append(json.dumps(key, ensure_ascii=False))
            out.append(":")
            _jcs(value[key], out)
        out.append("}")
    else:
        raise TypeError(f"cannot canonicalize {type(value).__name__}")


def canonical_json(obj) -> str:
    out: list = []
    _jcs(obj, out)
    return "".join(out)


def integrity_hash(obj) -> str:
    return hashlib.sha256(canonical_json(obj).encode("utf-8")).hexdigest()


def hash_fn_for(protocol_version: str | None):
    """Select the hash function an object was written under. Objects from
    protocol 0.1 (or rows predating per-object protocol stamps) verify
    with the legacy serialization; everything later uses RFC 8785."""
    return legacy_integrity_hash if protocol_version in (None, "0.1") else integrity_hash
