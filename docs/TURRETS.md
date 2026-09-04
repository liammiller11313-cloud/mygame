# Turrets

The Turret ability drops a gun that holds an angle. Since 0.9 it does two things
it did not: you can **sit in it and drive it**, and the **horde attacks it**.

## Manning it

Walk into the seat behind the gun. That is the whole interaction — no prompt, no
key. Jump to get out.

While you are in it:

- The gun aims where **your camera** points and fires on your **normal fire
  button**.
- Your own weapon is put away. The viewmodel goes off screen and the trigger does
  not fire it, because it is firing the turret instead.
- The bar over the turret reads **MANUAL** instead of **AUTO**.
- It shoots **half again as fast** — 4.5 rounds a second against the automatic
  3.0 — for the same damage per round.

Empty, it goes back to picking the nearest thing it can see.

**Why sit in it at all.** Damage per shot is identical on purpose. What you buy
is *choosing*: the automatic gun always shoots the Common two studs in front of
it, and a person shoots the Smoker on the roof, or the Tank, or the body about to
reach a downed teammate. Pricing that in damage as well would have made sitting
in it the only correct play.

**What it costs.** You cannot move, you cannot use your own gun, and everything
in the map is walking toward the noise.

## The horde attacks it

Infected within **22 studs** break off and swing at the turret with the same
windup, the same cooldown and the same damage they would spend on a person,
scaled by 2.5. Roughly:

| Attacking it | Time to destroy 250 HP |
|---|---|
| One Common | 22 s — it will not manage it alone inside the turret's lifetime |
| Five Commons | 4.5 s |
| One Charger | 5.8 s |
| One Tank | 3.1 s |

**Only five bodies at a time.** A turret that diverted a whole wave would be a
better crowd-control tool than the abilities designed to be one, and a wave that
walks past four survivors to punch a box has stopped being a threat. Five is
enough that a badly-placed turret dies in seconds and a well-placed one buys the
team a corridor.

A body only breaks off if the turret is **closer than the survivor it is already
chasing**, so a zombie with somebody in claw range never turns round.

This replaced proximity damage — health that ticked down while a crowd stood near
it. The numbers came out about the same and it read as the turret rusting rather
than being torn apart, and standing next to your own turret in a crowd was free.

## The health bar

Drawn over the turret rather than on your screen, because with up to four of them
in a map "which one is being torn apart" is a question about *where*. It shows:

- A health bar, white → amber → red.
- **AUTO** or **MANUAL**.
- **WALK IN TO TAKE CONTROL**, within 15 studs, when nobody is in it.

It does not draw through walls, and it stops drawing past 90 studs.

## Giving it your own model

`ServerStorage → Assets → Abilities → Turret`. See `docs/ABILITY_MODELS.md` for
the parts it looks for (`base`, `gun`, `Muzzle`…). Two things are new:

- **A `Seat` anywhere in your model is used as the gunner's seat.** Model a stool
  and players sit on it. Without one, an invisible seat is placed 2.2 studs behind
  the gun.
- The seat is **not collidable**, so it is not something to trip over in the
  doorway you are defending.

## Numbers

All in `AbilityConfig`, under the Turret definition's `tuning`:

| Key | Value | What it is |
|---|---|---|
| `Damage` | 14 | Per round, both modes |
| `FireRate` | 3.0 | Rounds a second, unmanned |
| `ManualFireRate` | 4.5 | Rounds a second, manned |
| `Range` | 70 | How far it will shoot |
| `Health` | 250 | |
| `Lifetime` | 30 | Seconds, then it packs up |
| `AggroRadius` | 22 | How close a body has to be to turn on it |
| `MaxAttackers` | 5 | How many can attack one turret at once |
| `AttackDamageScale` | 2.5 | A swing against it, as a multiple of a swing against a person |
