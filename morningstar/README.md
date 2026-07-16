# Morningstar v0.1

A provenance-preserving observational instrument for personal, emotional, and
epistemic development.

Morningstar is not a journaling app. It does not generate insight, advice, or
a story about you. It preserves a high-fidelity evidentiary record from which
later interpretations can be derived, compared, revised, and audited — because
the observer, the protocol, and the observed are parts of the same adaptive
system, and observation is itself an intervention. Morningstar doesn't try to
remove that coupling; it records enough context to make it visible later.

**Primary invariant:** later knowledge never rewrites earlier evidence.
Captures are append-only. Corrections, annotations, and interpretations are
new records that reference the original — never edits to it.

## Setup

Requires Python 3.12+. Everything runs locally; there is no account, no
cloud, no analytics, no telemetry, and no network call of any kind.

```bash
cd morningstar
python3.12 -m venv .venv          # or: uv venv --python 3.12
.venv/bin/pip install -e .        # or: uv pip install -e .
.venv/bin/python -m morningstar   # serves http://127.0.0.1:8765
```

Run the tests:

```bash
.venv/bin/pip install -e ".[dev]"
.venv/bin/pytest
```

## Usage

Open <http://127.0.0.1:8765>.

1. **New capture** — write naturally into three channels:
   - **Observation** — externally observable facts. Times, events, verbatim
     messages. No motives, explanations, or meaning.
   - **Phenomenology** — immediate subjective experience, in your own words.
   - **Action** — behavior actually performed, without justification.
2. **Context is collected automatically** — timestamp, timezone, versions,
   elapsed time since the previous capture, capture source. You may state
   optional extras (location, weather, sleep, heart rate) or skip them all.
3. **Review, then commit.** The preview may gently flag phrases that look
   like interpretation leaking into evidence ("because", motive claims,
   diagnoses, predictions). These flags explain themselves, never rewrite
   your text, and never block submission.
4. **Committed captures are immutable.** Later thoughts and corrections are
   added as annotations beneath the capture; the original never changes.
5. **Interpretation is a separate layer.** Interpretations reference captures,
   can be revised (with full revision history), branched, superseded, or
   discarded — and competing interpretations can coexist indefinitely.
   Morningstar never writes one for you.

**Conversational mode** asks only three questions — *What happened? What did
you experience? What did you do?* — and handles everything else.

**Audit** re-verifies the whole store on demand: event ordering, hash-chain
continuity, object hashes, references, and version registrations, in plain
language.

**Export** produces plain text (readable with no knowledge of the data
model), Markdown, or JSON (the complete archive including the event ledger).

## Data, backup, privacy

- All data lives in one SQLite file: `~/.morningstar/morningstar.db`
  (override the directory with `MORNINGSTAR_DATA_DIR`).
- **Backup** = copy that file. **Restore** = put it back.
- Captures may contain highly sensitive material — treat the data directory
  accordingly. v0.1 does not implement database-level encryption; use
  full-disk encryption. Device platform metadata (OS string, hostname) is
  recorded only if you explicitly opt in under Settings.

### Deletion vs. append-only provenance

These two goals genuinely conflict, so Morningstar offers both halves
explicitly:

- **Hide** removes a capture from normal view but keeps the evidence intact.
  Reversible. Prefer this.
- **Permanent deletion** irreversibly blanks the capture's content, its
  annotations, and the ledger entries that carried it. The row, its ordering,
  its original hash, and the chain remain — so the record shows *that*
  something existed and was deleted (the deletion is itself an event), but
  the content is unrecoverable and can no longer be verified against its
  hash. The audit screen reports this as a redaction, not as tampering.
  Earlier exports and backups are not reached.

## Integrity, honestly stated

Every stored object carries a SHA-256 hash of its canonical serialized
content; events and captures also chain to their predecessor's hash. This
provides **tamper evidence** — accidental corruption or casual edits will be
detected — not cryptographic proof against an adversary with full access to
the database file, who could rewrite the chain wholesale. Morningstar claims
nothing beyond what is implemented.

## What Morningstar Refuses to Do

Morningstar does **not**:

- diagnose you
- infer motives — yours or anyone else's
- determine objective meaning
- decide which interpretation is true
- rewrite earlier evidence
- optimize for emotional closure
- produce a more persuasive self-narrative
- punish incomplete capture
- require exhaustive metadata
- convert uncertainty into false precision

Integrity conditions (missing metadata, timestamp uncertainty, redactions)
are reported as instrument states, visibly and non-punitively — never as
user failures.

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design note: the
append-only event ledger, hash chaining, database-level immutability
triggers, schema/protocol versioning as first-class events, and the
unresolved trade-offs.
