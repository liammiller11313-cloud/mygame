# Alpha Testing 04

Build stamp is printed in the server log at boot. Check it first, before
reporting anything — it is the fastest way to tell whether the place you are in
is the build you think it is.

Since Alpha 02 this build has gained a **second side objective**, a **fourth
boss**, **eight weapons**, a **Robux pack**, a **code redemption system** and
two mechanics that change how a weapon is fired. There is more new surface here
than in any previous alpha, and most of it is on two maps.

---

## Before you invite anybody

Four things, in this order.

### 1. Read the boot banner

`failed` must be **0** on both the init and start lines, on the server and the
client. Everything else on that screen is information, not a fault.

Then read the **asset lines**. Anything on the grey-boxed side is a stand-in.
This build added models to three folders, so these are the ones to actually
look at:

```
ReplicatedStorage/Assets/Weapons        ClassicSword, ClassicPaintballGun,
                                        ClassicSlingshot, ClassicRocketLauncher,
                                        Tesla Rifle
ReplicatedStorage/Assets/Infected       Bacteria Monster
```

If any of those five weapons or the boss reads as grey-boxed, the output names
what it searched for. The most likely cause is a name that does not match
`modelName` — `ClassicRocketLauncher`, not `RocketLauncher`.

### 2. Watch for one new warning

```
[ViewmodelController] "X" has no Grip attachment, so its first-person rotation
is being measured rather than read.
```

New in this build, and it means the client is drawing a model the asset pipeline
never prepared. **That weapon will probably look rotated in your hands and
correct on a teammate** — the exact bug the tactical shotgun had. The fix is in
the message: keep models in `Assets/Weapons`, not `Assets/Viewmodels`.

### 3. Put the map props in

Two maps need props that did not exist at Alpha 02.

**Zombieville** — see `docs/ZOMBIEVILLE_GENERATORS.md`:

```
Zombieville
├── Puzzle
│   └── Generator 1 … Generator 5
└── Lootroom
    ├── Lootroom Gate       ← must be INSIDE Lootroom
    ├── Tesla Rifle
    └── Dollar Stackpile
```

**A missing generator turns the whole objective off for the round**, loudly,
naming the model it could not find. That is deliberate: four machines against a
counter that needs five is a round where the loot room can never open.

**Clinton** is unchanged from Alpha 02 and should be re-tested anyway — the
counter card, the vault door and the clue chain all moved through this build.

**The Backrooms** needs nothing new. It already has all six item families, ammo
crates and its spawns; the boss arrives on wave 15 on its own.

### 4. Run the checks

```
./scripts/check.sh
```

stylua, selene, then five auditors. All must pass. `audit.py` gained a check
this build that immediately found four pre-existing holes — see below.

---

## What is new

### Zombieville: five generators and a loot room

A second side objective, built to be a different activity from Clinton's vault
rather than a second one of it. The vault is a thing you **solve**, once,
standing still, by reading. This is a thing you **do**, five times, moving.

Five generators, powered in fixed numerical order 1 → 5. The route never moves —
that is what lets a team learn the map — while **which mini-puzzle waits at each
one is dealt fresh every round** from a pack of five.

| Panel | What you do |
|---|---|
| LOOM SPLICE | Press the terminal matching each lit wire |
| BREAKER PANEL | Throw five breakers in rating order — the line tells you which way |
| BUS VOLTAGE | Select three cells that add up to the target |
| FUEL PRESSURE | Stop a needle in a green band, three times, narrowing |
| PHASE ALIGN | Four dials, and each turns its right-hand neighbour too |

All of them are **presses**. No dragging — a drag is a mouse, and a controller
and a phone are two thirds of the audience. Wire colours are named as well as
coloured.

At 5/5 the gate vanishes, the room arms, the team is paid, a horde spawns around
the room, and **an arrow** points at it from wherever you are standing.

### The Tesla Rifle, and a weapon that charges

Zombieville's loot-room special, built against Clinton's flamethrower rather
than from it: a narrow long bolt with **penetration six** where the flamethrower
is a wide short igniting cone. One suits a building full of doorways, the other
a street with a sightline.

**It charges.** The first shot of a burst lands a third of a second after you
pull the trigger, and the charge then stays up for two seconds — so the tax is on
*starting* to shoot, not on shooting. **Letting go does not cancel it**: tap it
and the shot still lands, aimed wherever you are looking when it does.

This is the thing in the build I most want a verdict on. If it feels bad,
`spinUp` and `spinHold` in `WeaponConfig` are the two numbers and `spinUp = nil`
removes it entirely.

### The Backrooms: the Bacteria Monster

The first creature in the roster that belongs to **one map**. It replaces wave
15's boss on the Backrooms and switches off that wave's 50/50 substitution pool.

Tank says keep moving. Witch says don't make noise. Metallic says read the
arena. Underneath, a team beats all three the same way and none of them touch
it: **pick a room, cover the one door, put every gun on the same target.**

This one takes the room. It is slow, never charges, and can be walked away from
at any moment — but it seeds **colonies** on the floor that damage, slow you to
55%, and keep growing. On a slow drip where it walks, and **every 300 damage it
takes, one takes root under whoever it is chasing.** Four guns on one target
from one doorway is the fastest possible way to make that doorway
uninhabitable.

**Fire is the answer.** Highest burn damage in the game, and while it burns it
stops seeding entirely.

### Brickbattler's Pack — 100 Robux, or a code

Four classic tools translated rather than transplanted: sword, paintball gun,
slingshot, rocket launcher. They deal damage through **`DamageService`**, which
is the whole reason they were not left as their own tool scripts — a paying
player's kills earn XP, quests, Dollars and scoreboard position.

The slingshot and the rocket launcher **pogo**: shoot the ground under yourself
and get thrown. Capped at nine jumps high.

`OG-BRICKBATTLE` redeems the pack free plus 250 Dollars, in a two-hour window on
10 September, 4–6pm US Central. The CODES panel is in the main menu.

### Sound

The Tesla Rifle is the only weapon in the game with a **voice of its own** — six
cues rather than one, because it has no magazine to drop and no round to fail to
chamber, and played the shared reload bank it sounded like a rifle pretending.

The generators used to sound like a **menu**: every switch you threw was the
shop's hover tick, and a generator coming online made no noise in the world at
all. Now the start-up carries 260 studs, they hum while running, and the gate
rolls up.

---

## Bugs fixed for this build

The ones worth knowing about because they change what you should look at.

- **Both puzzle panels outlived the player.** They watched the round ending but
  not one player being grabbed or killed mid-round — and they draw *above* the
  incapacitated card, so a survivor pulled off a generator by a Hunter kept a
  full-screen puzzle over the screen telling them what happened.
- **No reach check on any puzzle interaction.** A crafted client could power all
  five generators, collect the whole clue chain and claim both stockpiles from
  the spawn point. A comment in the source claimed otherwise; it does now.
- **The loot-weapon stash was one global slot.** Clinton then Zombieville would
  fail to find a Tesla Rifle and restore the *flamethrower* into the loot room,
  at a CFrame from a building no longer loaded.
- **`SubmitVaultCode` on Zombieville was a runtime error** in a handler anyone in
  the server can reach.
- **A pair of pistols aimed off whichever sight came first in descendant order.**
- **The colonies' slow was written straight to `Humanoid.WalkSpeed`.**
  `SurvivorService` rewrites that property every frame, so the slow survived until
  the player sprinted and then vanished — while the creature still held a stale
  "real" speed to restore.
- **Overlapping colonies stacked damage**, three or four deep in a long fight,
  at several times the tuned rate.

### And four the new auditor found

`audit.py` gained a check that every special and boss appears in the tables that
make it real. It found four **pre-existing** holes on its first run:

- **Tongue, Boomer and Spitter had no grey-box shape.** `buildRig` returns nil
  without one, so if any of those three folders were misnamed or missing, the
  creature did not grey-box — it **never spawned at all**, silently. They are
  supplied models today, which is exactly why nobody had noticed.
- **The Witch had no kill-feed line**, in a table whose own comment claimed it
  covered every special.

---

## Known issues

Honest list. None of these are worth a report.

- **The Tesla Rifle's sounds are real; its recharge length is a guess.**
  `reloadTime` is 3.6s and the sample may not be. If there is dead air mid-reload
  or the sound is cut off, say how long the sample actually is.
- **The generator hum has not been verified as seamless.** Five running at once
  will make any loop click obvious.
- **The Backrooms has no side objective**, and that is normal rather than
  missing — so does Crossroads. The map itself is complete: all six item
  families, ammo crates and six spawns. It is a full test target.
- **Survivors now start on the loaded map's own SpawnLocations**, one per
  survivor, facing the way each pad points. Before this build the game searched
  all of Workspace and took the first SpawnLocation it found, which on a
  map-swapping game routinely belonged to a map that was not loaded — the team
  started the round outside the level. `FL_SurvivorSpawn` still overrides when a
  map tags one.
- **Two constants on the boss are untested by anyone**: 300 damage per bloom and
  a cap of 12 colonies. Whether that is uncomfortable or impassable is the thing
  play decides.
- **Being downed inside a colony is rough** — you cannot crawl out fast enough.
  That is consistent with the Spitter's acid, and it may still be too much.
- **Clinton's vault door still plays the menu-confirm tick.** The loot room's
  shutter would suit it better; it is a one-line change nobody has asked for yet.
- **`modelRotation` exists in `WeaponConfig` and no weapon uses it.** It is the
  escape hatch for a model that is rotated in a way the pipeline cannot measure —
  deliberately unused, not dead.
- Everything in Alpha 02's known-issues list that is not contradicted above still
  stands.

---

## The first session, in order

### A. Does it boot

Banner, `failed = 0`, asset lines. Then the new `no Grip attachment` warning.

### B. Zombieville, twice

Once to learn it, once to see the puzzles reshuffle.

1. Counter card reads `GENERATORS 0/5`, down the left.
2. Walk past generator 3 first — prompt should be **dim**, and pressing it gives
   *"Wrong generator, find the first one!"* on the card, with no panel.
3. Generator 1 is lit → panel opens. Play all five types across a round.
4. Try CLEAR mid-sequence, and a deliberately wrong answer — a 1.5s fault, panel
   stays open.
5. At 5/5: gate gone, *"Get to the loot room!"*, arrow with `LOOT ROOM ###m`,
   horde around the room.
6. Tesla Rifle picks up into Primary. **An ammo crate must not refill it.**
7. Second round without changing map: generators re-arm, rifle is back, puzzles
   are in a different order.

### C. The charge

Tap the Tesla Rifle. Hold it. Tap it again a second later, then again five
seconds later. The first of each engagement should be late and audibly charged;
the rest should not be.

### D. Clinton, one round

Counter card, four clues in order, keypad, flamethrower, stockpile. All of it
moved through this build.

### E. The pack

Redeem `OG-BRICKBATTLE` (or own the pass). All four equip. **Kills must earn XP
and Dollars** — that is the entire reason they were not left as tool scripts.
Pogo the slingshot and the rocket.

### F. The Backrooms, to wave 15

The one map in this build that needs a **full round played to the finale**,
because the boss only exists there and only on the last wave. Everything else
about the map is ordinary and should behave like Zombieville: items, crates,
spawns, the horde.

Watch for four things when the Bacteria Monster arrives:

1. It is announced as **BACTERIA MONSTER** and gets a boss bar.
2. Wave 15 sends it **instead of** the Apex Tank or the Metallic — every time,
   not half the time. If you get a Tank on the Backrooms, the map override did
   not fire.
3. The colonies grow, slow you, and **do not stack** where they overlap.
4. **Burn it.** Seeding should stop entirely while it is alight, and it should
   take damage faster than anything else in the game.

Then two things after it dies: the floor clears, and **nobody is left slow.**
That second one had two separate bugs in it this build, so it is worth checking
deliberately — get somebody downed inside a colony and revive them.

### G. Controller and phone

Every generator panel is presses only and was built for this. If any of the five
cannot be finished on a pad or a phone, that is the single most important thing
you can report from this build.

---

## Reporting

Build stamp, map, wave, and what you were doing. For anything visual, a
screenshot with the F9 console open is worth more than a description — most of
this build's failure modes print a line naming themselves.
