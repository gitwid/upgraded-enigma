# Experiment 001 — Defender (Williams, two-player cabinet)

```
status:      experimental / active
branches:    docs/ARCHITECTURE.md (parent design; unchanged by this note)
question:    does the Defender two-player cabinet hold relevant data on
             latency and verification — specifically the scoring system
             vs. the experience of losing a rescued humanoid?
confidence:  ~0.6 that the mappings below are load-bearing, not decorative
```

This is an interpretation-layer document about the instrument itself. It
references evidence; it does not modify the v0.1 protocol. Anything here
that graduates into the protocol requires a version increment like any
other schema/protocol change.

## Fact base

Verified against published game references (sources at the end); items
marked *(uncertain)* are stated at the precision actually available.

- Defender (Williams Electronics, 1980/81, Eugene Jarvis & Larry DeMar).
  The two-player cabinet is **alternating play**: one control set, players
  swap on death, and the machine holds each player's complete world —
  score, wave, humanoid population, planet state — and restores it
  exactly when their turn comes back around.
- Rescue mechanics: shooting a Lander mid-abduction frees the humanoid.
  Catching it in flight and returning it to ground: **500 points**. A
  dropped humanoid that survives the fall on its own: **250 points**.
  Wave-end bonus per surviving humanoid: **100 × wave number**, capped at
  500 from wave 5 on.
- If **all humanoids are lost, the planet explodes**; the game continues
  in open space and all Landers arrive as mutants — faster, more hostile.
  Every fifth wave the humanoid population is replenished.
- **The score never decrements.** There is no mechanism in the game by
  which a later event revises an earlier award. A humanoid rescued at
  09:48 is worth its 500 points forever, even if it is abducted and
  killed at 09:52.
- Every 10,000 points the machine grants an extra ship and a smart bomb.
- The cabinet is public. The score is kept by the machine, displayed in
  real time, and witnessed by whoever is standing there.

## Finding A — latency

The two-player cabinet is a clean experimental separation of the two
latencies Morningstar cares about, because it puts them side by side:

1. **Machine gap**: while player 2 plays, player 1's world is held in
   suspension. When it returns, it has not drifted by one pixel. The
   instrument's latency cost is zero.
2. **Operator gap**: player 1's *model* of their world has been decaying
   the whole time — which wave, which humanoids were where, how many
   smart bombs. The drift is entirely in the human.

Defender never confuses these, and neither must Morningstar: the
automatically measured `elapsed_since_previous_capture_seconds` (machine
gap) and the user-stated `recall_latency` (operator gap) are different
quantities and are already stored in different places (`automatic` vs.
`stated` context). The Defender datum is that this separation is what
makes the operator gap *measurable at all* — you can only see memory
drift against a record that didn't drift.

Second latency datum: on turn handoff, Defender **shows you your world
before giving you control** — the planet scrolls back in, restored. It
re-grounds the returning player in recorded state rather than asking
them to reconstruct it from memory. This transfers directly (see
Experiment E1 below).

Third, negative-space datum: Jarvis's design is famously intolerant of
input friction — everything about the cabinet optimizes the loop between
intention and effect. Morningstar's equivalent constraint is already
named in the protocol: excessive capture burden is an instrument
failure. The capture path must stay short.

## Finding B — verification

1. **Verification by instrument, not testimony.** The player never
   self-reports a score; the machine keeps it, in public view, in real
   time. Morningstar's automatic context collection is the same stance:
   the instrument measures what it can measure, so the operator's words
   can be reserved for what only the operator can report.
2. **The ledger is monotonic.** Nothing that happens later ever reaches
   back into the score. Four decades of arcade practice confirm that
   nobody experiences the non-deduction as dishonesty — the score is
   understood as a record of *what happened*, not of *how things stand*.
   This is the primary invariant, field-tested since 1981.
3. **Two registers, never one.** Defender keeps a cumulative ledger (the
   score) and a current condition (humanoid population, planet state) as
   separate registers. Losing a humanoid decrements the population; it
   does not touch the ledger. Conflating the two would force retroactive
   edits — the only way a single register can reflect a loss is to
   rewrite the past. Morningstar's split between the immutable event
   ledger and the mutable overlays (visibility, interpretation status as
   new revisions) is the same architecture. The Defender datum: this
   split is not an implementation convenience; it is the precondition
   for a record that can stay honest without punishing the present.
4. **Provenance can be tiny.** Three initials on the high-score table
   are enough identity for the claim being made. Human-scale provenance
   burden — the operator constraint, in cabinet form.
5. **Verification grants capacity; it does not judge.** At 10,000 points
   the machine hands you a ship and a bomb. It never says "good player."
   Morningstar's audit should keep this shape: its outputs are
   capacities (a verified export, a readable report), never verdicts.

## Finding C — the scoring system vs. the experience of losing a rescued humanoid

This is the center of the hunch, and it holds.

When a rescued humanoid is later lost, the machine records: the
abduction, the death, the decremented population, and — if it was the
last one — a **regime change**: the planet explodes and every future
Lander arrives as a mutant. What the machine never records: minus 500.
The rescue is not re-scored, reworded, or reframed. Consequences
propagate **forward** (the world gets harder); they never propagate
**backward** (the past is not revalued).

The player's experience is categorically different from all of this. A
rescued-then-lost humanoid hurts more than one never saved — the rescue
created an investment the score cannot see. The grief is real and it is
nowhere in the machine, *and both of these facts are correct*. Mapped to
Morningstar's channels:

- the score and the population count are **Observation** — externally
  verifiable events and states;
- the particular sting of losing what you had saved is
  **Phenomenology** — real evidence, belonging to the operator, in the
  operator's words ("surrender. fin de partie.");
- "I failed them" is **Interpretation** — the machine has no opinion,
  and the layer that holds opinions is revisable, branchable, and
  discardable precisely because it was never allowed to contaminate the
  first two.

Defender is thus an existence proof that the three layers can coexist
without the ledger lying and without the feeling being denied. The
scoring system does not optimize for emotional closure — the planet
just blows up, and the record of every rescue stands.

One more mapping worth keeping: the planet's explosion is recorded as a
**state-transition event with forward-only consequences** — structurally
the same thing as a Morningstar protocol/schema version change. The
world after the transition is different; captures made before it remain
readable under the regime in which they were made.

And the audience datum: the cabinet is public, spectators alter play,
and Defender makes no attempt to eliminate this — the coupling is simply
visible to everyone present. Morningstar takes the identical stance on
audience-effect drift: name it, record the capture source, do not
pretend the observer can be removed from the system.

## What must NOT transfer

Defender's ledger discipline transfers; **Defender's incentive loop must
be refused.** The score exists to make you play harder, chase
thresholds, and perform for the room. Importing streaks, counts,
milestones, or any capture-scoring into Morningstar would optimize for
exactly what the instrument refuses to do: produce a more persuasive
self-narrative and punish incomplete capture. The hunch therefore
yields a negative result as well as positive ones — take the
bookkeeping, leave the dopamine.

## Experiments

- **E1 — re-entry grounding (implemented on this branch).** On starting
  a new capture, the interface shows one non-interpretive line: how long
  ago the previous capture was committed. This is Defender's
  restore-the-world-before-handing-back-control move: ground the
  returning operator in recorded state instead of asking memory to do
  it. It is display only — it adds nothing to the capture record that
  wasn't already collected — and it says nothing about what the gap
  *means*.
- **E2 — `outcome` annotation type (proposed only).** A dedicated
  annotation type for "what later became of this" — forward-linked
  consequence recording, the planet-explosion pattern at capture scale.
  Deferred: `note` already carries this; a new type is worth adopting
  only if outcome-tracking turns out to be a real usage pattern.
- **E3 — capture scoring / streaks (considered and refused).** See
  "What must NOT transfer."

## Verdict

The hunch is confirmed in the specific sense: the two-player cabinet
separates machine latency from operator latency more cleanly than any
single-player system could, and the scoring system's refusal to revalue
a rescue after the humanoid's death — while the loss lands fully in the
player and in the world's future difficulty — is a working, 45-year-old
demonstration of Morningstar's primary invariant and its channel
separation. Confidence that the analogy is load-bearing rather than
decorative: moderate (~0.6). The strongest claims (monotonic ledger,
two registers, forward-only consequences) are directly observable in
the game; the latency reading depends on taking alternating play as a
model of recall, which is an interpretive move.

## Sources

- [Wikipedia — Defender (1981 video game)](https://en.wikipedia.org/wiki/Defender_(1981_video_game))
- [StrategyWiki — Defender/Walkthrough](https://strategywiki.org/wiki/Defender/Walkthrough)
- [shmup.fandom.com — Defender](https://shmup.fandom.com/wiki/Defender)
- [Game Developer — The History of Defender: The Joys of Difficult Games](https://www.gamedeveloper.com/business/the-history-of-i-defender-i-the-joys-of-difficult-games)
- [Doug Mahugh — Defender chapters](https://www.dougmahugh.com/defender-chapter02/)
