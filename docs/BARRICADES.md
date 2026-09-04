# Breakable barricades

Set a part's **Material** to `Wood` in Studio. That is the whole authoring
contract — no tag, no attribute, no naming convention, no script inside the
model. `WoodPlanks` counts too.

The horde will path around it if there is another way. When there is not, the
bodies pile against it and start swinging, and it comes apart.

## What arms, and what does not

A wooden part is armed when **all** of these are true:

| | |
|---|---|
| Material | `Wood` or `WoodPlanks` |
| Anchored | yes — loose wood is furniture, not a barricade |
| CanCollide | on — nothing is behind a part you can walk through |
| Transparency | below 1 — an invisible barricade is a body swinging at nothing |
| Volume | between 1.5 and 900 studs³ |
| Shape | not floor-like — see below |

The **floor test** is the one that is not obvious, and it exists because the
obvious guards do not cover the case that matters. A plank floor is not one big
part the volume window catches; it is forty door-sized ones, anchored, colliding
and wooden, and every other test above passes them. A horde that can eat the
floor drops the team into the void.

What separates them is which way the part is *thin*. A floor is thin
**vertically**; a door, a wall and a board nailed across a window are thin
**horizontally**, whatever their other dimensions do and however the part itself
is rotated. So the thinnest axis is taken into world space and its Y component
checked. Cubes are exempt — a crate is thin in no particular direction.

Worked examples:

| Part | Size | Armed | Health |
|---|---|---|---|
| Door leaf | 4 × 7 × 0.5 | yes | 350 |
| One plank across a window | 5 × 0.6 × 0.5 | yes | 150 |
| Shop counter | 10 × 3.5 × 1.2 | yes | 1050 |
| Crate | 4 × 4 × 4 | yes | 1200 |
| Floor plank | 4 × 0.5 × 4 | **no** | floor-like |
| Big floor slab | 50 × 1 × 50 | **no** | volume 2500 |
| Skirting trim | 8 × 0.4 × 0.2 | **no** | volume 0.64 |

Health is volume × 25, clamped to 150–1200. A door is a door-sized amount of
work and a boarded shopfront is more.

## If the scan gets it wrong

Put the parts that should be breakable in a folder called **`Barricades`**
anywhere in the map. When that folder exists, **only** what is inside it is
armed, and nothing in there is second-guessed — no material test, no size
window, no floor test. You put it there on purpose.

The material contract is the good default and it is still a heuristic: it has to
guess, on a map this code has never seen, which wooden things were meant to be
obstacles. When it guesses wrong the answer should be a folder you drag six
parts into, not a set of numbers you tune until the trim stops being edible.

Watch the Output window on the first round of a map:

```
[BarricadeService] armed 7 barricade(s) in Clinton (wooden parts, found by material)
```

Past 60 it warns, because a map with that many breakable things in it is a map
where the furniture got armed along with the doors.

## How fast it comes down

| | dps | A 350 hp door |
|---|---|---|
| One Common | 10.7 | 33 s |
| Six Commons | 64 | 5.4 s |
| One Tank | 82 | 4.3 s |

Damage is the body's own claw damage × 3, so the roster's hierarchy carries over
without a second damage table to keep in step with the first. One Common alone
grinding for half a minute is correct: a single zombie should not get through.

## Two things it deliberately does not do

**Bullets do not damage it.** This is the horde's tool, not the team's. A
survivor who can shoot through the map's carpentry opens the flanks the level
designer closed.

**A broken barricade is hidden, not destroyed.** `MapService:ensure` is a no-op
when the team votes to replay the map they are already on — nothing reloads, so
anything a round destroys is still destroyed at the start of the next one. Three
properties are snapshotted when a part is armed and put back when the next round
arms. A replayed Clinton gets its doors back.
