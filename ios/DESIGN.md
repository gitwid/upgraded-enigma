# Morningstar iOS — design note

The native iOS app carries the **Morningstar protocol** (append-only
observational instrument, protocol 0.2, RFC 8785 hashing — the Python app in
`../morningstar/` is the reference implementation) and wears the
**navigational principle and end-user experience of the Digital Mindfulness
site** (`../index.html`, `../style.css`).

The site's code is the *design source*, not a spec to conform to. Its CSS is a
draft; we translate the experience it describes, not its markup. What we
extracted is the navigation grammar and the felt arc — the rest is redrawn.

## Principle extraction (site mechanism → iOS idiom)

| Site mechanism (`index.html` / `style.css`) | iOS translation |
| --- | --- |
| Frontpage `<ul>` of four glyph links (`☥ ☁ ☉ ☯`) | `HubView` glyph portal — same four glyphs, same order |
| Names hidden behind `:hover` tooltips | Names sit quietly beneath each glyph (hover doesn't exist on touch); VoiceOver reads "name — role" |
| Each section opens with its glyph linking back to `#nav-id` | Journey header glyph = return to hub, everywhere |
| Full-screen `.page` sections, `scroll-behavior: smooth` | `JourneyView` full-screen stages with smooth slide transitions |
| Linear journey Breath → Mind → Eye → Play | The capture liturgy, in that exact order |
| Mind's purposeless `<textarea>` + `Refresh` reset | The wander pane: never persisted; Refresh clears it |
| Eye's grid where every tile advances | Review stage where every choice moves forward (leakage chips never block) |
| Play's "enjoy… then continue your day, refreshed" | Commit as arrival: haptic settle, then release to hub |

## The skin (kept: Breath → Mind → Eye → Play)

Per the project decision, the site's stage names and glyphs are preserved and
re-meant onto the instrument:

- **☥ Breath — Arrive.** Re-entry grounding (Experiment 001's E1: Defender's
  restore-the-world-before-handing-back-control). A slow breathing pulse and
  the non-interpretive re-entry line ("your previous capture was committed N
  ago"). Reads nothing into the gap.
- **☁ Mind — Observe.** The three evidence channels (*what happened / what did
  you experience / what did you do*) plus the ephemeral wander pane.
  Interpretation is not invited here; it is a separate, later layer.
- **☉ Eye — Review.** The draft, with gentle leakage chips flagging possible
  layer crossings. Every path is forward; nothing blocks submission.
- **☯ Play — Commit.** The capture settles into the ledger, immutable from
  that instant, then releases you.

## Architecture

- **`MorningstarKit`** (SwiftPM, iOS 17 / macOS 14) — the portable domain core,
  a faithful port of the Python reference:
  - `JCS.swift` — RFC 8785 canonicalization, same algorithm as
    `../morningstar/morningstar/canonical.py`. The golden vectors
    (`Tests/.../Resources/jcs_vectors.json`, a byte-copy of the reference
    fixture) are the acceptance gate: the Swift core may claim to verify a
    store only while every vector reproduces byte-for-byte. CI diffs the two
    fixture copies so they can never drift.
  - `Integrity.swift` — SHA-256 over canonical UTF-8 (CryptoKit). Protocol
    0.1-era objects are reported `.legacyUnverifiable` — never re-hashed.
  - `Models.swift` — `hashContent()` mirrors the exact content dictionaries in
    `store.py`, so Swift hashes equal Python hashes byte-for-byte.
  - `Leakage.swift` — the reference rule table, non-blocking.
  - `SQLite.swift` / `Migrations.swift` / `SQLiteStore.swift` — the store, at
    parity with `store.py` (see below).
  - `FileEventStore.swift` — **superseded**; retained only so ledgers written
    by the interim build stay readable.
- **`MorningstarApp`** (SwiftUI, XcodeGen `project.yml`) — the shell described
  above. Glass chrome, paper evidence: controls float on translucent material,
  evidence text stays plain and inert.

## Storage

`SQLiteStore` is the store, at parity with the reference implementation: the
same DDL, the same append-only triggers and `_guard` maintenance latch, the
same event ledger and hash chains, version registries, `capture_visibility`
overlay, hide-vs-redact, and interpretation revision/branch tables. A database
written by either implementation is the same database.

**Raw SQLite3, not GRDB** (this note previously named GRDB). The reasoning
follows the reference implementation's own (`../morningstar/docs/ARCHITECTURE.md`):
this domain is append-only — rows are inserted, never updated — so an ORM's
central machinery is exactly what the design must prevent, and plain SQL keeps
the schema and its triggers inspectable and byte-identical to the reference.
It also adds no dependency, which matters here because the cloud container has
no Swift toolchain: macOS CI is the only compiler, so unverifiable third-party
API surface is a real risk. Reversible later without changing the store API.

Immutability is enforced three ways, as in the reference: no update API on
evidence, SQLite triggers that reject `UPDATE`/`DELETE` (so even hand-written
SQL against the file fails), and hash verification. Redaction is the single
sanctioned mutation: it opens the latch inside one transaction, blanks the
capture, its annotations, and the event payloads that carried the content,
keeps rows/ordering/original hashes so the chain stays continuous, and appends
a `capture_redacted` event. The audit reports redactions as warnings, never as
tampering.

`FileEventStore` (the interim JSONL ledger) is superseded and kept only for
reading old ledgers. **Follow-up:** no automatic ledger→SQLite import exists;
captures from an interim ledger can be read with `FileEventStore` and
re-committed deliberately. Nothing shipped on the interim store, so no real
evidence is affected.

One deliberate difference from the reference: timestamps here are ISO-8601 with
millisecond precision (Swift's `ISO8601DateFormatter`) where Python writes
microseconds. Both are opaque strings to the protocol — hashes cover whatever
string was recorded — so this affects nothing but appearance.

## Capture at event speed (protocol 0.3)

The protocol has always recorded `recall_latency` — an admission that memory
degrades between an event and the writing of it. Nothing in the app did
anything about that gap; the four-stage journey widens it. Protocol 0.3 adds a
fast path.

- **The `unsorted` channel.** A quick capture records one blurt of text,
  explicitly *not* separated into observation / phenomenology / action. This is
  the honest record: at speed nobody has decided which part is which, and
  filing it into a channel it may not belong in would be a small lie told by
  the software. `nil` on captures written through the journey.
- **Sorting later is an annotation, never an edit** (`sortLater`). Deciding
  afterwards what was observation and what was already interpretation is later
  knowledge *about* the evidence. The original stays exactly as taken down, and
  its hash is untouched.
- **Immediacy is never asserted.** A quick capture records `capture_source`
  (the path taken — a fact) and leaves `recall_latency` unstated. Whether you
  spoke at the moment or three hours later is yours to say, not the app's to
  assume.
- **No leakage checks on the fast path.** They belong to a review step and
  there isn't one here. Nothing may stand between a person and recording what
  just happened.
- **Dictation needs no code.** The system keyboard's microphone runs on-device;
  no speech leaves the phone. Any other kind of dictation would be
  unacceptable here.

**Versioned hashed content.** `unsorted` joins hashed capture content *from 0.3
onward*, and content is always rebuilt from each object's own recorded protocol
version (`Morningstar.contentIncludesUnsorted`). Without that, bumping the
protocol would silently invalidate every capture written before it — the exact
failure the "never re-hash history" rule exists to prevent. `QuickCaptureTests`
pins this: a 0.2-era row still verifies in a 0.3 store, beside 0.3 captures.

### Guardrails (deliberately absent features)

Speed invites compulsion, so the fast path is bounded on purpose. There are
**no streaks, no counts, no capture reminders, no notifications, no
"you haven't recorded today"** — the app never asks you to capture, and never
rewards frequency. `AppShortcut` phrases exist so *you* can reach the
instrument quickly; nothing reaches back. The re-entry line stays a single
factual sentence about elapsed time and reads nothing into it.

## Desktop-only (not doable in the cloud build container)

- Building/running the app (Xcode + iOS SDK). `brew install xcodegen && cd
  ios/MorningstarApp && xcodegen`, then open and run on a simulator. CI here
  only runs `swift test` on `MorningstarKit` (the domain core).
- HealthKit (sleep, heart rate) and Core Location / WeatherKit for optional
  context — each behind explicit per-source consent, as the protocol's consent
  model already anticipates.
- File-level encryption via iOS Data Protection, closing v0.1's "no database
  encryption" trade-off.

## Non-goals (explicit)

The **S Framework** and its lineage (LP / Liminal Proximity, R / Resource
Equity, S-capacity, S-coherence, the "singularity-proximity" index) are **not
implemented and not to be implemented** here. They are conceptual writing, not
a specification. Recorded as a named non-goal so no future pass mistakes them
for scope. Likewise unchanged from the protocol: no analytics, no telemetry, no
network calls, no account, no cloud. The instrument is local-first by
construction.
