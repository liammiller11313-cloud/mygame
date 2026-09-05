# Bosses

Three creatures set `isBoss`. Two of them are fights and one of them is a hazard,
and that split matters more than the flag does — the Witch is meant to be tiptoed
past, so she is the only one with no health bar and the only one whose arrival
does not push the AI Director to its peak state. The set lives in
`InfectedConfig.PeakBosses`; anything that needs to tell a fight from a hazard
reads it rather than naming kinds again.

| | Health | Fire does | Bar | Counter |
|---|---|---|---|---|
| **Witch** | 1000 | 45/s | no | avoid her, or kill her in one go |
| **Tank** | 4000 | 150/s | yes | keep moving, fire in turns, burn it |
| **Metallic** | 6000 | **25/s** | yes | don't be in the lane, then fill the window |

---

## The Metallic

The thing above a Tank, and deliberately not a bigger one. Every mechanic is
aimed at one of the three answers a team already has for a Tank:

- **Move as a unit** → the **pound**. A shockwave around its own feet. Standing
  shoulder to shoulder next to it is the mistake.
- **Fire in turns** → the **charge**. It is *slower* than a Tank and can be
  walked away from — and then it crosses the gap in one committed line. Backing
  down a corridor is the mistake. Sidestepping is the answer.
- **Burn it** → **nothing**. `burnDamagePerSecond` is 25 against the Tank's 150.
  A team that opens with the molotov that always worked has spent it.

### The window

The charge always ends in an **overheat**: a couple of seconds rooted, silent,
taking **double damage**, announced out loud and shown on the boss bar, which
pulses and reads `EXPOSED`. Almost all of the damage this thing takes should be
taken in those seconds. A boss with no window is just a boss with more health.

Two ways to get one, and the second is the interesting one:

1. Survive the charge and wait for it to run out.
2. **Bait it into a wall.** The charge stops on world geometry, so a pillar
   behind you converts a dodge into a full window several seconds early. Reading
   the arena beats this thing faster than reading the boss.

The window is not free forever. Below a quarter health the window is **40% shorter**
and it decides what to do next sooner — the same quarter the Tank enrages on and the
same quarter the boss bar goes hot, so it is one tell learned once.

### It is not a sequence

What it does next is a weighted roll re-taken every few seconds and biased by
where the team is standing: close in it usually pounds, far out it charges, and
in the middle band it just keeps walking. Nothing is on a fixed cycle, so there
is no pattern to count.

---

## The Tank

Unchanged in the ways that matter — four thousand health, immune to stagger,
faster than a survivor who stops to shoot, swing and rock. What changed is that
no two of them are the same any more.

### The opening

Rolled when it stands up, spent within about ten seconds, and it decides what the
first thing you see it do is:

- **Charge** — straight in, roaring, no rock at all through the arrival.
- **Artillery** — opens at range with a rock, before anyone has necessarily
  found it.
- **Stalk** — walks in at survivor pace and **says nothing**. No roar, no
  announcement, until either its clock runs out or it hits somebody — and then it
  roars. The audio cue a team relies on to locate a Tank is simply absent until
  it is already in the room. This is the frightening one.

### Tempo

Every body gets its own multiplier on every cooldown it waits out. Its real job
is the pack: two Tanks released three seconds apart on identical timing swing in
unison, which reads as one enormous attack instead of two, and a dodge that beats
one beats both.

### Enrage

Below a quarter health it roars, moves 10% faster and acts noticeably oftener.
Deliberately modest — the last quarter of a Tank should be the hardest quarter,
not a different creature — and deliberately aligned with the boss bar going hot,
so the readout a team is already watching is the warning.

---

## What the round actually sends

`GameModeConfig.Waves` still puts a boss on **5, 8, 11 and 15**. That rhythm is
fixed. What is no longer fixed is *which* boss, or how many.

### Substitution

From wave 8 on, a wave may send something other than what it declares. A team
that has played four rounds knows a Tank is coming on 11; it should not also
know it is a Tank.

| Wave | Declares | May instead send |
|---|---|---|
| 5 | Tank | — nothing. This wave teaches the Tank. |
| 8 | Witch | Tank, 30% |
| 11 | Tank | Metallic or Witch, 40% |
| 15 | Apex Tank | Metallic, 50% |

A **substitute never inherits the wave's elite tier**. Wave 15's Apex triples
health, which on a Tank is the finale and on a Metallic is eighteen thousand
health and a fight nobody finishes. So the last wave is either an Apex Tank or a
plain Metallic, and those are meant to be about equally hard by completely
different routes. The ELITE WAVE modifier follows the same rule.

The callout always tells the truth. Whatever the wave *announced*, the shouted
line names what actually walked in.

### The pack

A Tank can arrive with company, and **only** a Tank — two Witches is two ambushes
that never interact, and two Metallics is two charge lanes through one corridor.
Two Tanks is the one doubling that stays a fight.

Scaled by how many survivors are **on their feet** when the wave lands, not by
lobby size: four in the match with two of them down is a team of two for as long
as that lasts.

| Survivors upright | Second Tank | Third |
|---|---|---|
| 1–2 | never | never |
| 3 | 25% | never |
| 4 | 35% | 20% of those |

Only on waves that opt in (`bossPack`), which today is 8 and 11. Not wave 5 — you
cannot learn the fight from two of them — and not on an Apex, which is already
that wave's escalation. Pack members arrive three seconds apart so they come
through a doorway rather than as a wall.

---

## Models

Drop rigs into `ServerStorage/Assets/Infected/<Kind>/`. The folder may be named
whatever you called it: a definition can set `modelFolder`, which is tried before
the kind id — the Metallic ships as **`Assets/Infected/Metallic Boss/`** holding a
rig called `Metallic`, and that works as-is. Several rigs in one folder are
treated as variants and picked between.

Anything missing is grey-boxed from the definition's colours and scale, and the
server prints which kinds are still empty at boot.

## Audio

All six `Metallic*` cues are existing samples re-pitched — see
`docs/AUDIO_NEEDED.md` for what they should be. **Wind** and **vent** are the two
worth replacing first: they are the only warning before a charge and the only
signal that the window is open, and the fight is unreadable without them.
