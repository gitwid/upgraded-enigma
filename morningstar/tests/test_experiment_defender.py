"""Experiment E1 (docs/experiments/001-defender-two-player.md):
re-entry grounding. On starting a new capture, show how long ago the
previous capture was committed — recorded state offered back to the
operator, Defender-handoff style. Display only, never interpretive,
never part of the new capture's record."""

from morningstar.app import humanize_seconds


def test_no_reentry_line_on_first_capture(client):
    for path in ("/capture/new", "/chat"):
        assert "previous capture" not in client.get(path).text


def test_reentry_line_after_a_capture(client):
    client.app.state.store.commit_capture(observation="door closed")
    for path in ("/capture/new", "/chat"):
        page = client.get(path).text
        assert "Your previous capture (capture 001) was committed" in page
        assert "ago." in page


def test_reentry_is_display_only(client):
    # The line states elapsed time; it must not read meaning into it,
    # and it must not leak into the next capture's stored record.
    store = client.app.state.store
    store.commit_capture(observation="first")
    page = client.get("/capture/new").text
    for interpretive in ("too long", "should", "gap means", "streak"):
        assert interpretive not in page
    second = store.commit_capture(observation="second")
    ctx = second["context_snapshot"]
    assert "reentry" not in str(ctx)
    # The machine gap is measured where it always was — automatic context.
    assert ctx["automatic"]["elapsed_since_previous_capture_seconds"] is not None


def test_humanize_seconds():
    assert humanize_seconds(30) == "less than a minute"
    assert humanize_seconds(59 * 60) == "59m"
    assert humanize_seconds(2 * 3600 + 14 * 60) == "2h 14m"
    assert humanize_seconds(3 * 86400 + 5 * 3600) == "3d 5h"
