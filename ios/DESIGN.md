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

## Contextual permissibility (protocol 0.4)

The organizing question is no longer *who may grant this* but *what may
legitimately occur here* — given this actor, action, environment, consent, and
constraints. Three regimes describe how the membrane responds:

| Regime | Posture |
| --- | --- |
| **Sponge** | Accommodation. Ambiguity, friction, and harmless variation pass without escalation. |
| **Pressure** | Legible resistance. The approaching constraint is made perceptible, with adjustment or withdrawal offered instead of silent failure. |
| **Edge** | Inviolable. The impermissible does not happen — including prohibited acquisition or disclosure. |

**Permissibility is normative; permeability is technical.** A technically
possible operation may still be impermissible. This layer therefore *adds* to
the existing boundary and replaces none of it: the SQLite append-only triggers
and the hash chain remain the enforcement, and an assessment never unlocks
them. The one pre-existing consent gate (`deviceMetadataConsent`) is untouched.

### The rules, and why they are ordered

`PermissibilityPolicy.assess` is pure and evaluated in this order:

1. **Refusal is an edge, always.** No regime, metaphor, or satisfied condition
   rescues a withdrawn consent.
2. **A sensitive action without consent is `undetermined`** — never permitted
   by default. Sensitive means acquisition, retention, or disclosure.
3. **Named constraints produce `conditional`**, so the boundary is perceptible
   before it is hit. The caller must confirm the conditions; this layer cannot
   verify what it only names.
4. Otherwise, accommodate.

`undetermined` is deliberately **not** sponge but pressure: unresolved should
be felt, not silently accommodated and then failed. And `mayProceed` refuses
`undetermined` for every sensitive action, which is the whole of the interrupt
*do not let a softer interaction metaphor weaken hard consent boundaries*
expressed as code.

### Assessments are records, not flags

A `PermissibilityAssessment` is an append-only row in its own table with its
own integrity hash, cited evidence, and `permissibility_assessed` event. It is
kept apart from captures on purpose: an assessment may be superseded as
context moves; the observation it concerns must never be silently rewritten —
the same separation the interpretation layer already keeps.

- **Supersession is derived, not written.** The latest assessment for an
  (actor, action, environment) governs; nothing is ever updated in place. A
  tie resolves to the *more restrictive*, so a race cannot widen permission.
- **Staleness degrades to `undetermined`.** A permission past its `validUntil`
  stops permitting rather than continuing by inertia, and the audit reports it.
- **No assessment at all is `undetermined`,** not permitted.
- Assessments are verified like any other record; tampering with one is as
  visible as tampering with a capture.

`withPermission` re-reads the governing assessment *inside* the write
transaction, so a withdrawal recorded between assessment and action is seen
rather than raced past.

### Register — what 0.4 does and does not establish

| Register | Finding |
| --- | --- |
| ESTABLISHED | Refusal, staleness, absence, and conflict all resolve against permission, under test |
| ESTABLISHED | Assessments are append-only, hashed, evidence-linked, and audited |
| ESTABLISHED | Capture immutability and the triggers are unchanged by this layer |
| PROVISIONAL | Sponge–Pressure–Edge as the right decomposition of response |
| OPEN | Distributed consent, identity verification, multi-process enforcement |
| OPEN | Independent evaluation by a second participant |

The concurrency claim is bounded and stated in the tests themselves: writes
serialize on one connection. That is not a claim about distributed consent or
identity, and `testConcurrencyClaimIsBoundedToOneConnection` exists to keep
the boundary of the claim visible rather than implied.

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
