"""Canonicalization contract (protocol 0.2, RFC 8785).

The golden vectors are the portable artifact: any other implementation
(e.g. a native Swift port) must reproduce them byte-for-byte before it
may claim to verify a Morningstar store.
"""

import hashlib
import json
from pathlib import Path

import pytest

from morningstar.canonical import (
    _es6_number,
    canonical_json,
    hash_fn_for,
    integrity_hash,
    legacy_canonical_json,
    legacy_integrity_hash,
)

GOLDEN = Path(__file__).parent / "golden" / "jcs_vectors.json"


def test_golden_vectors_reproduce():
    data = json.loads(GOLDEN.read_text(encoding="utf-8"))
    assert data["protocol_version"] == "0.2"
    assert data["vectors"], "fixture must not be empty"
    for vector in data["vectors"]:
        canonical = canonical_json(vector["value"])
        assert canonical == vector["canonical"], vector["name"]
        assert integrity_hash(vector["value"]) == vector["sha256"], vector["name"]
        # the hash is over UTF-8 bytes of the canonical form
        assert hashlib.sha256(canonical.encode("utf-8")).hexdigest() == vector["sha256"]
        # canonical form must round-trip to an equal value
        assert json.loads(canonical) == vector["value"], vector["name"]


def test_es6_number_formatting():
    # Known ECMAScript String() outputs — verifiable in any JS engine.
    cases = {
        0.0: "0", -0.0: "0", 1.0: "1", 0.5: "0.5", 4.50: "4.5",
        2e-3: "0.002", 1e21: "1e+21", 1e20: "100000000000000000000",
        1e-6: "0.000001", 1e-7: "1e-7",
        333333333.33333329: "333333333.3333333",
        1.5e21: "1.5e+21", 5e-324: "5e-324",
        1.7976931348623157e308: "1.7976931348623157e+308",
        -42.75: "-42.75",
    }
    for value, expected in cases.items():
        assert _es6_number(value) == expected, value


def test_nan_infinity_and_unsafe_ints_rejected():
    for bad in (float("nan"), float("inf"), float("-inf")):
        with pytest.raises(ValueError):
            canonical_json({"x": bad})
    with pytest.raises(ValueError, match="IEEE-754"):
        canonical_json({"x": 2**53 + 1})
    canonical_json({"x": 2**53 - 1})  # max safe int is fine


def test_utf16_key_ordering():
    # U+FF01 < U+1F600 by code point, but the emoji's UTF-16 high
    # surrogate (0xD83D) < 0xFF01 — JCS requires the emoji first.
    out = canonical_json({"！": 1, "\U0001f600": 2})
    assert out.index("\U0001f600") < out.index("！")
    # naive code-point sorting would produce the opposite
    assert sorted(["！", "\U0001f600"])[0] == "！"


def test_legacy_serialization_is_frozen_and_different():
    obj = {"confidence": 1.0, "text": "émotions ✓"}
    assert legacy_canonical_json(obj) == '{"confidence":1.0,"text":"émotions ✓"}'
    assert canonical_json(obj) == '{"confidence":1,"text":"émotions ✓"}'
    assert legacy_integrity_hash(obj) != integrity_hash(obj)


def test_hash_fn_selection_by_protocol():
    assert hash_fn_for("0.1") is legacy_integrity_hash
    assert hash_fn_for(None) is legacy_integrity_hash  # pre-0.2 rows
    assert hash_fn_for("0.2") is integrity_hash
    assert hash_fn_for("0.3") is integrity_hash  # future versions stay JCS
