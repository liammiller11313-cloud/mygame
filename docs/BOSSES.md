# Bosses

Four creatures set `isBoss`. Two of them are fights and one of them is a hazard,
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
| **Bacteria Monster** | 3000 | **200/s** | yes | burn it, and stop standing still |

---

## The Bacteria Monster

**Backrooms only.** The first creature in the roster that belongs to one map —
see `MapConfig.finaleBoss`, which replaces wave 15's boss on that map and
switches off its 50/50 substitution pool, because a boss exclusive to a map is
not exclusive if a coin flip can swap it for a Metallic.

### The answer it takes away

The other three each remove one habit and leave the rest — keep moving, don't
make noise, read the arena. Underneath, a team beats all three the same way, and
none of them touch it: **pick a room, cover the one door, put every gun on the
same target.**

This one takes the room.

### How

It is **slow**. No charge, no leap, walks below survivor pace. You can leave
whenever you like. You just can't *stay*.

It seeds **colonies** — growth on the floor that damages, slows you to 55%, and
keeps spreading after it lands. Two sources:

1. **Where it walks**, on a slow drip every 26 studs. On its own that's a Spitter
   with a longer fuse.
2. **Where it's shot.** Every 300 damage it takes, a colony takes root a few
   studs short of whoever it's chasing — which is whoever has been shooting
   hardest.

That second one is the fight. Four guns on one target from one doorway is the
fastest possible way to make that doorway uninhabitable. The better a team is at
the fight they already know, the sooner they have to leave the place they were
winning it from.

### The counter is fire

`burnDamagePerSecond` is **200** — the highest in the game, eight times the
Metallic's — and **while it burns it stops seeding entirely**. Damage taken while
alight isn't banked either, so burning it is a way to *stop* the blooms, never a
way to defer them.

That's deliberate symmetry. The Metallic exists partly to take the opening
molotov away from a team that throws one at every boss; this hands it straight
back as the whole answer.

### It is not a damage race

3000 health — under a Tank's, half a Metallic's. The fight is a timer on the
team's **position**, not on its ammunition. At Metallic health the colonies would
eat the whole floor before it died, which isn't pressure, it's a wipe with a
longer preamble.

When it dies the floor clears and everyone gets their legs back. A finale that
left the map poisoned would make winning feel like losing more slowly.

### Adding another map-exclusive boss

One line: `finaleBoss = Enums.Infected.<Kind>` on that map's `MapConfig` entry.
`rollBosses` takes it from there — last wave only, pool off, tier dropped.

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

> An Apex is not currently any *bigger* than a plain Tank, only tougher. Its
> tier asks for ×1.12 scale, and that is applied by writing the Humanoid's scale
> values — which the asset pipeline deletes from every template on purpose, so
> spawning cannot scale a rig twice. Health and damage land; size does not.
> Listed here because it is invisible from the config and surprising.

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

Anything missing is grey-boxed, including the Metallic, so a wave that asks for
one always gets something. The server prints which kinds are still empty at boot.

### Size

Most kinds are sized by `scale`, a plain multiplier — right for anything standard,
since every Common and special is a normal humanoid rig.

**The Metallic is sized by `targetHeight` instead: 17 studs, whatever it arrives
as.** The pipeline measures the rig and works out the multiplier itself. Build it
at any size you like — the game will make it 17 studs tall and keep its
proportions. That is deliberate: a boss has to read as bigger than the last boss
*and* still fit through the doors the last one fits through, and neither of those
is a fact about the units it was modelled in.

Seventeen is measured against **a Tank**, which boots at about 13.6 studs — so
the Metallic is a quarter taller, unmistakable across a street, and every map is
already laid out to pass a Tank with room.

> This number was 14 for a while, against a Tank of 10.6. That 10.6 was the
> *grey-box* Tank — the fallback rig built out of parts when nothing is supplied,
> which the shipped game has never used. A real Tank is an artist's rig and
> measures 13.6, so the Metallic was arriving at x1.03 of one: the same size,
> which is the one thing this creature must not be.

The boot line prints every boss's finished size (`bosses (tall x wide)`) and
warns by name if one stands more than **1.35 x a Tank**. A ratio rather than a
number of studs, for exactly the reason above: nothing in the pipeline can know
an artist's units in advance, and the Tank can never fail its own check.

The rig is stripped on import: its own `Script`, `Animate` and `Sound` objects
are removed so nothing fights the game's audio or animation. Animation **ids**
are lifted out first, so a rig that carries its own clips keeps them.

## Movement

Two things a seventeen-stud body needs that a normal one does not.

**It cannot get stuck.** Two escalating answers, both on a three-second progress
check. First it stops trusting pathfinding and walks the straight line. If that
also makes no progress, it winds up and charges — and the charge moves the body
directly rather than through the navmesh, so a pathing failure physically cannot
block it. It has no jump at all (a machine on drills does not hop), which is why
the second answer has to exist.

**The charge follows the floor.** It is a horizontal move, so without correction
it would bury itself going up a ramp and fly going down one. Each frame it puts
itself back on whatever is underneath. Finding *no* floor ends the charge — so it
stops at the lip of a roof rather than launching off it, and a team cannot beat
it by standing near an edge.

## Audio

All six `Metallic*` cues are existing samples re-pitched — see
`docs/AUDIO_NEEDED.md` for what they should be. **Wind** and **vent** are the two
worth replacing first: they are the only warning before a charge and the only
signal that the window is open, and the fight is unreadable without them.
