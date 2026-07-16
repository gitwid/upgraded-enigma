"""Web-flow tests: the operator never behaves like a database."""

import re


def commit_via_form(client, **overrides):
    fields = {
        "observation": "08:47 rcvd: message", "phenomenology": "disappointment",
        "action": "ended exchange", "recorded_at": "", "source": "",
        "recall_latency": "", "location": "", "weather": "",
        "sleep_duration": "", "heart_rate": "", "capture_source": "form",
    }
    fields.update(overrides)
    resp = client.post("/capture/commit", data=fields, follow_redirects=False)
    assert resp.status_code == 303
    return resp.headers["location"]


# 11. The user never needs to enter an internal ID.
def test_user_never_enters_internal_id(client):
    # The capture form asks for natural text only — no id-like inputs.
    form_html = client.get("/capture/new").text
    named_inputs = re.findall(r'name="([^"]+)"', form_html)
    assert not any("id" in name.lower() for name in named_inputs)

    # Full flow: commit → the server assigns the id and hands back the URL.
    location = commit_via_form(client)
    detail = client.get(location)
    assert detail.status_code == 200
    assert "Capture 001" in detail.text

    # Annotating uses that same server-issued URL; the form has no id field.
    annotate_inputs = re.findall(r'name="([^"]+)"', detail.text)
    assert "body" in annotate_inputs
    assert not any(re.fullmatch(r".*_id|id", n) for n in annotate_inputs)
    resp = client.post(f"{location}/annotate",
                       data={"type": "note", "body": "later thought"},
                       follow_redirects=False)
    assert resp.status_code == 303

    # Interpretation: captures are picked by checkbox, never typed ids.
    new_interp = client.get("/interpretations/new").text
    assert 'type="checkbox" name="capture_ids"' in new_interp


# 9 (web half). Leakage warnings do not block submission.
def test_leakage_warning_shown_but_submission_allowed(client):
    fields = {
        "observation": "she left because she wanted to punish me",
        "phenomenology": "", "action": "", "recorded_at": "", "source": "",
        "recall_latency": "", "location": "", "weather": "",
        "sleep_duration": "", "heart_rate": "", "capture_source": "form",
    }
    preview = client.post("/capture/preview", data=fields)
    assert preview.status_code == 200
    assert "Possible layer leakage" in preview.text
    assert "Commit capture" in preview.text  # commit stays available
    location = commit_via_form(client, **{"observation": fields["observation"]})
    assert "she left because she wanted to punish me" in client.get(location).text


def test_conversational_mode_three_questions(client):
    page = client.get("/chat")
    assert "What happened?" in page.text
    step2 = client.post("/chat", data={"step": "0", "observation": "door closed",
                                       "capture_source": "conversational"})
    assert "What did you experience?" in step2.text
    step3 = client.post("/chat", data={"step": "1", "observation": "door closed",
                                       "phenomenology": "confusion",
                                       "capture_source": "conversational"})
    assert "What did you do?" in step3.text


def test_preview_review_then_commit_becomes_immutable(client):
    fields = {
        "observation": "project merged", "phenomenology": "excitement",
        "action": "submitted capture", "recorded_at": "~14:00", "source": "memory",
        "recall_latency": "right away", "location": "", "weather": "",
        "sleep_duration": "", "heart_rate": "", "capture_source": "form",
    }
    preview = client.post("/capture/preview", data=fields)
    assert "Review before committing" in preview.text
    assert "project merged" in preview.text
    location = commit_via_form(client, **fields)
    store = client.app.state.store
    cap_id = location.rsplit("/", 1)[1]
    cap = store.get_capture(cap_id)
    assert cap["recorded_at"] == "~14:00"
    assert cap["committed_at"]


def test_hide_delete_and_audit_pages(client):
    location = commit_via_form(client)
    cap_id = location.rsplit("/", 1)[1]

    confirm = client.get(f"{location}/delete")
    assert "irreversibly" in confirm.text and "Hide instead" in confirm.text

    client.post(f"{location}/hide", follow_redirects=False)
    assert "capture 001" not in client.get("/").text
    assert "capture 001" in client.get("/?hidden=1").text
    client.post(f"{location}/unhide", follow_redirects=False)

    client.post(f"{location}/delete", data={"confirm": "yes"},
                follow_redirects=False)
    store = client.app.state.store
    assert store.get_capture(cap_id)["redacted"]

    audit = client.get("/audit")
    assert audit.status_code == 200
    assert "Integrity check passed" in audit.text
    assert "redacted" in audit.text  # surfaced as a visible, non-punitive warning


def test_exports_over_http(client):
    commit_via_form(client, observation="sent: “Are you free tomorrow?”")
    for path, marker in (("/export/archive.txt", "MORNINGSTAR"),
                         ("/export/archive.md", "# Morningstar archive"),
                         ("/export/archive.json", '"morningstar-archive"')):
        resp = client.get(path)
        assert resp.status_code == 200
        assert marker in resp.text
        assert "Are you free tomorrow?" in resp.text
