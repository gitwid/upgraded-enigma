"""Leakage checks are gentle: they warn, explain, and never block."""

from morningstar.leakage import check_capture, check_text


def test_flags_causal_and_motive_language():
    warnings = check_capture(
        observation="she cancelled because she wanted to avoid me",
        phenomenology="sad",
        action="left",
    )
    reasons = " ".join(w.reason for w in warnings)
    assert any(w.matched_text.lower() == "because" for w in warnings)
    assert "causal" in reasons
    assert "motives" in reasons or "inner state" in reasons
    # Every warning explains itself and offers a path, not a command.
    for w in warnings:
        assert w.reason
        assert "keep it as written" in w.suggestion


def test_phenomenology_is_not_policed_for_felt_states():
    # "feeling rejected", "depressed" as felt experience: no diagnosis flag
    # in the phenomenology channel.
    assert check_text("phenomenology", "feeling rejected. depressed. chest pressure.") == []


def test_clean_observation_passes():
    assert check_capture(
        observation='meeting ended 14:17. sent: "Are you free tomorrow?"',
        phenomenology="warmth, then confusion",
        action="accepted invitation, took out trash",
    ) == []


# 9 (store half). Leakage warnings do not block submission.
def test_warnings_never_block_commit(store):
    text = "he was trying to hurt me because he is a narcissist"
    warnings = check_capture(text, "", "")
    assert warnings  # plenty to flag...
    cap = store.commit_capture(observation=text)  # ...and it commits anyway
    assert store.get_capture(cap["id"])["observation"] == text  # unchanged
