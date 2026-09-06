# Alpha Testing 02

Build stamp **`2026-09-06u-alpha02`**. It is printed in the server log at boot
and is the fastest way to tell whether the place you are in is the build you
think it is — check it first, before reporting anything.

---

## Before you invite anybody

Six things, in this order. The first three are the ones that have actually gone
wrong before.

### 1. Press Play in Studio and read the boot banner

It is one screen of output and it answers most of what a first playtest would
otherwise discover the slow way.

```
  modules     37 of 37 loaded
  init        37 ran, 0 failed
  start       37 ran, 0 failed
```

(37 on the server; the client boots 46 controllers and prints its own banner.)

**`failed` must be 0 on both lines.** A module that fails init is now skipped at
start rather than run half-built, so one broken service is one line rather than
a cascade — but it is still a service the game does not have.

Then the asset line. Anything on the grey-boxed side is a stand-in, not a bug:

```
  assets      weapons 32 supplied / 5 grey-boxed · viewmodels 32 / 5 · infected 10 / 0
```

### 2. Check the new asset ids resolved

Three checks run on the **client**, so open the client console (F9) after
joining, not just the server output. Each names the thing rather than a number:

- `[ImageCheck]` — the menu photograph, the three map cards, the splash mark.
  It now also refuses a **decal** id, which is the mistake that cost a day: the
  id shown on a Creator Store page wraps the image rather than being it.
- `[SoundCheck]` — all 68 audio ids, in one preload. **Silence is not proof of
  success here** — `AudioConfig` ships deliberate blanks, so a missing cue reads
  as an unfinished row.
- `[PlaceholderFactory]` — which weapons and rigs are still stand-ins.

> **The failure mode you cannot see from your own machine.** Both images and
> audio are licensed per *place*. An asset uploaded under a personal account
> into a group-owned experience loads perfectly in Studio for whoever uploaded
> it and fails for every other player. If a tester reports something missing
> that works for you, this is the first thing to check.

### 3. Put the map items in

Six folders per map. Missing folders are not fatal — the Director falls back —
but the map-item warnings at boot tell you exactly which are absent:

```
Medkits/           Medkit 1 … 11
Pain Pills/        Pain Pills 1 … 9
Adrenaline Shots/  Adrenaline Shot 1 … 7
Molotovs/          Molotov 1 … 6
Pipe Bombs/        Pipe Bomb 1 … 7
Hazardous Wastes/  Hazardous Waste 1 … 7      ← new this build
```

### 4. Run the checks

```
./scripts/check.sh
```

Format, undefined names, the code audit, **every remote's two ends**, **every
item chain**, and the economy model. All six must be clean.

The remote check is new this build and it is worth knowing what it is for: a
remote has two halves in two different files, and a missing half is invisible —
no error, no warning, just a button that does nothing. That is not hypothetical
here. Every throwable in the game was inert for weeks because the client sent
`ThrowItem` and nothing listened.

### 5. Test on a phone and a controller, not only a desktop

Three schemes, and two of them cannot be checked by reasoning. See
`docs/CONTROLS.md` for the full table.

### 6. Decide what you are testing

The list below is what changed. An alpha that tests everything tests nothing.

---

## What is new since Alpha 01

### Two new items

**Hazardous waste** — a throwable, seven per map, and it **replaces the bile
jar**, which is gone. Both put a puddle on the floor that the horde walks to,
and two items doing that are one item and a copy of it.

The waste is the one worth keeping: fifty seconds, wide, and it coats nobody. A
pipe bomb is thrown at a horde that is already on you; this is put down *before*
one, on the corridor you have decided not to defend, and it is still running
when the wave arrives. Watch whether players work that out without being told,
or whether they throw it at things like a grenade.

**Flare gun** — a secondary, $3,500 in the shop. Twelve damage on impact, which
will not kill a Common; what it does is set them alight. One shell, four-second
reload. Watch whether the trade reads as interesting or just weak.

### Throwing changed

The **fire button now throws** a selected throwable, aimed down the camera. This
is the single most likely thing to need retuning — `G` still works, and on a pad
or a phone the fire button is now the primary route.

### Bodies stay

Ordinary kills leave a corpse instead of bursting. Commons gibbed on any
headshot from any gun before this, which deleted the body. Expect the map to
look substantially different during a horde; watch the frame rate on a phone.

### Boomers pop

They could not before. One flag was answering two questions.

### Boomer bile actually covers your screen

It did not. `applyBile` set the flag the server reads and never told the client,
so the only thing in the game that ever drew the green wash was a thrown bile
jar — which is why it looked fine in testing and the Boomer's entire threat did
not exist. **Test this deliberately**: let one burst on you and check that you
are blinded for about eleven seconds, and about seven from a vomit.

---

## Frame rate: what changed, honestly

You asked whether it is the same as before. Mostly yes, with one deliberate
exception, and one thing that was fixed before it shipped.

**The corpse ceiling has not moved.** It was 48 and it is still 48. What changed
is that it will now actually be *reached* — ordinary kills used to gib, which
deleted the body, so the ring rarely filled. Per body, once it stops moving:

- every part is **anchored** — no physics, and no physics replication
- the Humanoid's **state machine is switched off** — forty-eight corpses are not
  forty-eight state machines
- the client's pose loop **early-returns** on a dead body, and is strided and
  distance-culled besides

So a settled corpse costs draw calls and essentially nothing else. That is what
made 48 affordable when the number was chosen; the difference is that the number
is no longer theoretical. **Watch a phone during a wave 12 horde** — this is the
one change most likely to show up on a handset, and it is not device-scaled,
deliberately: corpses are replicated instances every client shares, so one
player's hardware must not decide how many bodies everyone else sees.

**The hazardous waste's particles were cut before shipping.** As first written it
put roughly 450 large soft particles on screen at four zones, against the bile
jar's 126 — three and a half times the most expensive thing this system could
previously do, on a zone that also lasts two and a half times as long. These are
server-side emitters on a replicated part, so a phone cannot scale them the way
it scales a blood burst. Retuned to 183: more than the jar, because it is a
bigger and longer-lived thing, and not a different order of cost.

**Nothing else added per-frame work.** The new asset checks run once at join
(one `PreloadAsync` for the whole sound bank, which also warms it, so the first
gunshot of a round is not the one that streams in late). The nav-agent sizing is
computed once per body when its brain is built, off a measurement cached per
kind.

---

## Textures

Supplied models keep their textures. The pipeline strips scripts, sounds,
prompts and stray `ThumbnailCamera`s from anything you hand it — and writes no
colour, material or texture of its own. Recolouring happens only in the
grey-box builder, which is the path a model *replaces*.

So if a model of yours looks flat or untextured in game, it is not this pipeline
doing it: check the model in Studio, and check the client console for an
`[ImageCheck]` or `[PlaceholderFactory]` line naming it.

---

## Known issues

Honest list. None of these are worth a report.

- **The ambush and fake-out are gone**, not broken — deleted rather than left as
  tuned config for a feature with no code path. See `docs/BACKLOG.md`.
- **Three audio cues are defined and never played**: `UI.MenuPage`,
  `WeaponReload.Bolt`, `Gore.Squelch`. Re-checked this build against all 92
  cues in the bank; it is still exactly these three.
- **The ammo-crate broadcast has no consumer.** The server tells everyone which
  crate went and when it returns; only the person who used it is told anything.
- **`MainMenuController` is at 181 top-level locals** against Luau's 200 limit.
  It compiles. It will stop compiling if it keeps growing.
- **Jump on iPad** is unverified since the pad was reworked — the original
  report predates that change and nobody has re-tested it.

---

## What to actually watch for

Ranked by how likely it is to be wrong, not by how bad it would be.

1. **Does the fire button throwing feel right**, or does it eat clicks people
   meant as shots?
2. **Is the hazardous waste legible** as area denial rather than a grenade —
   from the floor, in a dark room, before anybody explains it?
3. **Frame rate during a horde on a phone**, now that bodies persist.
4. **The flare gun's damage.** Twelve is deliberately almost nothing.
5. **Anything on a controller or a phone that a desktop player would not find.**

---

## Reporting

A report needs three things to be actionable: **the build stamp**, **the
platform**, and **what you expected instead**. The third matters most — several
of the bugs fixed for this build were code doing exactly what a comment said it
should, where the comment had been wrong for months.
