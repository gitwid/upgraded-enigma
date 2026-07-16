"""Local web interface.

Everything is server-rendered and runs on 127.0.0.1. There are no
external calls of any kind: no analytics, no telemetry, no CDN assets,
no AI. The API docs endpoints are disabled to keep the surface to the
pages themselves.
"""

from __future__ import annotations

import os
from datetime import datetime, timezone
from pathlib import Path

from fastapi import FastAPI, Form, HTTPException, Request
from fastapi.responses import HTMLResponse, RedirectResponse, Response
from fastapi.templating import Jinja2Templates

from . import export as export_mod
from .config import APP_VERSION
from .leakage import check_capture
from .store import NotFoundError, Store

CHAT_STEPS = [
    {"field": "observation", "question": "What happened?",
     "hint": "Externally observable facts only — times, messages, events. "
             "Verbatim quotes are welcome."},
    {"field": "phenomenology", "question": "What did you experience?",
     "hint": "Immediate feelings and sensations, in your own words."},
    {"field": "action", "question": "What did you do?",
     "hint": "Behavior actually performed. No justification needed."},
]

CAPTURE_FIELDS = ("observation", "phenomenology", "action", "recorded_at",
                  "source", "recall_latency", "location", "weather",
                  "sleep_duration", "heart_rate", "capture_source")


def humanize_seconds(seconds: int) -> str:
    days, rest = divmod(seconds, 86400)
    hours, rest = divmod(rest, 3600)
    minutes, _ = divmod(rest, 60)
    if days:
        return f"{days}d {hours}h"
    if hours:
        return f"{hours}h {minutes}m"
    if minutes:
        return f"{minutes}m"
    return "less than a minute"


def default_data_dir() -> Path:
    return Path(os.environ.get("MORNINGSTAR_DATA_DIR")
                or Path.home() / ".morningstar")


def create_app(data_dir: str | Path | None = None) -> FastAPI:
    store = Store(data_dir or default_data_dir())
    app = FastAPI(title="Morningstar", docs_url=None, redoc_url=None,
                  openapi_url=None)
    app.state.store = store
    templates = Jinja2Templates(directory=str(Path(__file__).parent / "templates"))

    def render(request: Request, name: str, **ctx) -> HTMLResponse:
        ctx.setdefault("app_version", APP_VERSION)
        return templates.TemplateResponse(request, name, ctx)

    def capture_or_404(capture_id: str) -> dict:
        try:
            return store.get_capture(capture_id)
        except NotFoundError:
            raise HTTPException(status_code=404, detail="capture not found")

    def interpretation_or_404(interpretation_id: str) -> dict:
        try:
            return store.get_interpretation(interpretation_id)
        except NotFoundError:
            raise HTTPException(status_code=404, detail="interpretation not found")

    def reentry_line() -> str | None:
        # Experiment E1 (docs/experiments/001): ground the returning
        # operator in recorded state — one factual line, no reading of
        # what the gap means. Display only; nothing is added to the
        # capture record.
        captures = store.list_captures(include_hidden=True)
        if not captures:
            return None
        last = datetime.fromisoformat(captures[-1]["committed_at"])
        elapsed = int((datetime.now(timezone.utc) - last).total_seconds())
        return (f"Your previous capture (capture "
                f"{captures[-1]['sequence_number']:03d}) was committed "
                f"{humanize_seconds(elapsed)} ago.")

    # -- home ----------------------------------------------------------

    @app.get("/", response_class=HTMLResponse)
    def index(request: Request, hidden: int = 0):
        captures = store.list_captures(include_hidden=bool(hidden))
        return render(request, "index.html", captures=captures,
                      show_hidden=bool(hidden))

    # -- capture flow --------------------------------------------------

    @app.get("/capture/new", response_class=HTMLResponse)
    def capture_new(request: Request):
        return render(request, "capture_new.html", values={},
                      reentry=reentry_line())

    def _form_values(form: dict) -> dict:
        return {k: (form.get(k) or "").strip() for k in CAPTURE_FIELDS}

    @app.post("/capture/preview", response_class=HTMLResponse)
    async def capture_preview(request: Request):
        values = _form_values(dict(await request.form()))
        if values.get("back") == "1":
            return render(request, "capture_new.html", values=values)
        warnings = check_capture(values["observation"], values["phenomenology"],
                                 values["action"])
        context_preview = store.build_automatic_context(
            values["capture_source"] or "form")
        return render(request, "capture_preview.html", values=values,
                      warnings=warnings, context_preview=context_preview)

    @app.post("/capture/edit", response_class=HTMLResponse)
    async def capture_edit(request: Request):
        values = _form_values(dict(await request.form()))
        return render(request, "capture_new.html", values=values)

    @app.post("/capture/commit")
    async def capture_commit(request: Request):
        v = _form_values(dict(await request.form()))
        capture = store.commit_capture(
            observation=v["observation"],
            phenomenology=v["phenomenology"],
            action=v["action"],
            recorded_at=v["recorded_at"],
            source=v["source"],
            recall_latency=v["recall_latency"],
            stated_context={k: v[k] for k in
                            ("location", "weather", "sleep_duration", "heart_rate")},
            capture_source=v["capture_source"] or "form",
        )
        return RedirectResponse(f"/capture/{capture['id']}", status_code=303)

    @app.get("/capture/{capture_id}", response_class=HTMLResponse)
    def capture_detail(request: Request, capture_id: str):
        capture = capture_or_404(capture_id)
        return render(request, "capture_detail.html", capture=capture,
                      annotations=store.annotations_for(capture_id),
                      interpretations=store.interpretations_for_capture(capture_id))

    @app.post("/capture/{capture_id}/annotate")
    def capture_annotate(capture_id: str, type: str = Form("note"),
                         body: str = Form(...)):
        capture_or_404(capture_id)
        store.annotate(capture_id, type, body)
        return RedirectResponse(f"/capture/{capture_id}", status_code=303)

    @app.post("/capture/{capture_id}/hide")
    def capture_hide(capture_id: str):
        capture_or_404(capture_id)
        store.hide_capture(capture_id)
        return RedirectResponse("/", status_code=303)

    @app.post("/capture/{capture_id}/unhide")
    def capture_unhide(capture_id: str):
        capture_or_404(capture_id)
        store.unhide_capture(capture_id)
        return RedirectResponse(f"/capture/{capture_id}", status_code=303)

    @app.get("/capture/{capture_id}/delete", response_class=HTMLResponse)
    def capture_delete_confirm(request: Request, capture_id: str):
        return render(request, "delete_confirm.html",
                      capture=capture_or_404(capture_id))

    @app.post("/capture/{capture_id}/delete")
    def capture_delete(capture_id: str, confirm: str = Form("")):
        capture_or_404(capture_id)
        if confirm != "yes":
            return RedirectResponse(f"/capture/{capture_id}/delete", status_code=303)
        store.redact_capture(capture_id)
        return RedirectResponse("/", status_code=303)

    # -- conversational capture ----------------------------------------

    @app.get("/chat", response_class=HTMLResponse)
    def chat_start(request: Request):
        return render(request, "chat.html", step=0, steps=CHAT_STEPS,
                      values={}, reentry=reentry_line())

    @app.post("/chat", response_class=HTMLResponse)
    async def chat_step(request: Request):
        form = dict(await request.form())
        step = int(form.get("step", "0"))
        values = _form_values(form)
        values["capture_source"] = "conversational"
        next_step = step + 1
        if next_step < len(CHAT_STEPS) + 1:
            return render(request, "chat.html", step=next_step,
                          steps=CHAT_STEPS, values=values)
        warnings = check_capture(values["observation"], values["phenomenology"],
                                 values["action"])
        context_preview = store.build_automatic_context("conversational")
        return render(request, "capture_preview.html", values=values,
                      warnings=warnings, context_preview=context_preview)

    # -- interpretations -------------------------------------------------

    @app.get("/interpretations", response_class=HTMLResponse)
    def interpretations(request: Request):
        return render(request, "interpretations.html",
                      interpretations=store.list_interpretations())

    @app.get("/interpretations/new", response_class=HTMLResponse)
    def interpretation_new(request: Request, parent: str = "",
                           capture: str = ""):
        parent_interp = interpretation_or_404(parent) if parent else None
        return render(request, "interpretation_new.html",
                      captures=store.list_captures(include_hidden=True),
                      parent=parent_interp, preselect=capture)

    @app.post("/interpretations/new")
    async def interpretation_create(request: Request):
        form = await request.form()
        capture_ids = form.getlist("capture_ids")
        confidence = (form.get("confidence") or "").strip()
        interp = store.create_interpretation(
            title=(form.get("title") or "").strip() or "Untitled interpretation",
            body=form.get("body") or "",
            capture_ids=list(capture_ids),
            parent_interpretation_id=(form.get("parent") or "").strip() or None,
            confidence=float(confidence) if confidence else None,
        )
        return RedirectResponse(f"/interpretations/{interp['id']}", status_code=303)

    @app.get("/interpretations/{interpretation_id}", response_class=HTMLResponse)
    def interpretation_detail(request: Request, interpretation_id: str):
        interp = interpretation_or_404(interpretation_id)
        referenced = [store.get_capture(cid)
                      for cid in interp["referenced_capture_ids"]]
        return render(request, "interpretation_detail.html", interp=interp,
                      referenced=referenced,
                      captures=store.list_captures(include_hidden=True))

    @app.post("/interpretations/{interpretation_id}/revise")
    async def interpretation_revise(request: Request, interpretation_id: str):
        interpretation_or_404(interpretation_id)
        form = await request.form()
        confidence = (form.get("confidence") or "").strip()
        store.revise_interpretation(
            interpretation_id,
            title=(form.get("title") or "").strip() or None,
            body=form.get("body") or None,
            capture_ids=list(form.getlist("capture_ids")) or None,
            confidence=float(confidence) if confidence else None,
        )
        return RedirectResponse(f"/interpretations/{interpretation_id}",
                                status_code=303)

    @app.post("/interpretations/{interpretation_id}/status")
    def interpretation_status(interpretation_id: str, status: str = Form(...)):
        interpretation_or_404(interpretation_id)
        store.set_interpretation_status(interpretation_id, status)
        return RedirectResponse(f"/interpretations/{interpretation_id}",
                                status_code=303)

    # -- audit / export / settings --------------------------------------

    @app.get("/audit", response_class=HTMLResponse)
    def audit(request: Request):
        return render(request, "audit.html", report=store.verify_integrity(),
                      events=store.recent_events(20),
                      schema_versions=store.schema_versions(),
                      protocol_versions=store.protocol_versions())

    @app.get("/export", response_class=HTMLResponse)
    def export_page(request: Request):
        return render(request, "export.html")

    @app.get("/export/archive.txt")
    def export_txt():
        return Response(export_mod.export_text(store), media_type="text/plain; charset=utf-8",
                        headers={"Content-Disposition": 'attachment; filename="morningstar-archive.txt"'})

    @app.get("/export/archive.md")
    def export_md():
        return Response(export_mod.export_markdown(store), media_type="text/markdown; charset=utf-8",
                        headers={"Content-Disposition": 'attachment; filename="morningstar-archive.md"'})

    @app.get("/export/archive.json")
    def export_json():
        return Response(export_mod.export_json(store), media_type="application/json",
                        headers={"Content-Disposition": 'attachment; filename="morningstar-archive.json"'})

    @app.get("/settings", response_class=HTMLResponse)
    def settings(request: Request):
        return render(request, "settings.html", store=store)

    @app.post("/settings")
    def settings_save(device_metadata_consent: str = Form("")):
        store.set_device_metadata_consent(device_metadata_consent == "on")
        return RedirectResponse("/settings", status_code=303)

    return app
