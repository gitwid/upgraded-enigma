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
  - `FileEventStore.swift` — interim append-only JSONL ledger + hash chain +
    `verifyIntegrity()`.
- **`MorningstarApp`** (SwiftUI, XcodeGen `project.yml`) — the shell described
  above. Glass chrome, paper evidence: controls float on translucent material,
  evidence text stays plain and inert.

## Storage roadmap

`FileEventStore` is the v0 substrate: one canonical-JSON event per line,
hash-chained, replayed on load. It holds the primary invariant (nothing
rewritten; every write appends an event; verification re-derives everything)
but not yet the reference implementation's full surface. The next milestone,
on desktop, is a **GRDB/SQLite store** with database-level immutability
triggers, hide-vs-redact, capture-visibility overlay, and the interpretation
revision/branch tables — reaching parity with `store.py`.

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
