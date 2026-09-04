# Abilities are part of a loadout now

## What changed

Abilities used to be one pair for the account — the same two whichever kit you
spawned with. They now live **on the loadout**, so each of your three kits
carries its own two:

```
LOADOUT 1        LOADOUT 2
  PRIMARY   AK-12    PRIMARY   HK417
  SIDEARM   M1911    SIDEARM   .357 Magnum
  MELEE     Machete  MELEE     Knife
  ABILITY 1 SHIELD   ABILITY 1 AIRSTRIKE
  ABILITY 2 MEDIC    ABILITY 2 TURRET
```

Switching loadouts switches abilities with them.

## Two doors, one thing

The loadout screen and the ability panel edit the **same** slots. The panel is
still where you buy them; equipping from either place writes into whichever
loadout is active, so the two can never disagree.

Storage-wise the loadout table gained two keys (`Ability1`, `Ability2`) beside
the three weapon slots. One flat map rather than a weapons table next to an
abilities table, which meant the wire format, the save, `sanitise`, `equal` and
the copy-on-edit in the UI all covered abilities without being told about them.

An ability slot may be **empty**. That is the one place the two halves genuinely
differ: everybody spawns with a gun, and nobody starts owning an ability.

## Your old abilities are not lost

A profile saved before this change has loadouts with no ability keys at all,
which would have logged you in with both slots empty and nothing saying why. On
load, every loadout that has nothing equipped is seeded from the old global
pair — so you come back with what you had, on all three, and can then make them
differ. It only touches loadouts that are empty, so it cannot overwrite a choice
already made.

## Cooldowns are five minutes

All five abilities, up from 30–90 seconds. Against a 1020-second round that is
three or four uses of one ability in a whole match.

That is the point. At thirty seconds a Shield was something you pressed whenever
it was lit, and the interesting question about an ability is not *whether* to use
it but *when*. Five minutes makes every activation a decision you remember
making, and makes bringing two of them a real choice rather than a formality.

The number is still per-ability in `AbilityConfig`, so the spread can come back
if it turns out an Airstrike and a Field Medic do not want the same clock.

**Cooldowns clear at the start of every round.** They already cleared when a
round *ended*, which is the normal path and not the only one — a server that
empties returns to the lobby without ending a round, and a player can leave a
match and come back to a fresh one. Cheap insurance at thirty seconds; worth
being certain about at five minutes, where carrying one over is a third of the
next match spent waiting.

One honest gap: a solo pause does **not** freeze ability cooldowns. Pausing for
five minutes refreshes one. It is only reachable when you are alone in the
server, so it is cheating at solitaire — see `docs/PAUSE_AND_LEAVING.md`.

## The rows scroll now

Three weapon slots already fitted tightly under the preview — the comment on
`PREVIEW_HEIGHT` records the bottom row landing exactly on the SET ACTIVE button
when melee made it three. Five rows do not fit a 430-pixel phone panel at any
row height, so the slot rows live in a scroller sized to whatever space there
is. It costs one frame and stops this being a question the next time a kit grows
something worth carrying.
