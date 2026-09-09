# The Vault Puzzle — what to put in the map

An optional side objective for **Clinton**. Four documents scattered around the
KFC, one keypad, one locked room. The code is different every round and is never
written down anywhere — it is spread across the four documents, and the fourth
one is what tells you how to arrange the other three.

Nothing about the KFC changes. No walls, no counters, no signage, no rebuild.
This is four props and a model you already have.

---

## Where the clues go

```
Clinton
├── KFC Code Door          ← already there, untouched
│   ├── Door
│   └── (the keypad face, B0-B9, Clear, Enter)
└── Puzzle                 ← make this folder
    ├── Clipboard          clue 1
    ├── House Number       clue 2
    ├── ID Card            clue 3
    └── Note               clue 4
```

Make a **Folder** called `Puzzle` directly under `Clinton` and drag the four
models into it. The folder is optional — the whole map is searched as a fallback
— but it keeps them together and makes the search cheaper.

`KFC Code Door` **stays exactly where it is.** It does not move into the folder.

Naming is forgiving: case, spaces, punctuation and a trailing plural are all
folded away, so `IDCard`, `id card` and `ID Cards` are the same object. You do
not tag anything; the game tags them itself when a round starts.

---

## The four clues, in order

They must be collected **in this order**. Interacting with one out of turn is
refused and the counter tells the player which one they are missing.

| # | Object | What it is | The digit sits in |
|---|---|---|---|
| 1 | `Clipboard` | Security report on a clipboard | `SQUAD ASSIGNMENT: 6` |
| 2 | `House Number` | Room sign on a wall | `ROOM 2` |
| 3 | `ID Card` | Officer's badge | `ID: 9` |
| 4 | `Note` | Handwritten post-it | `squad, room, id, then 4.` |

The code is those four digits **in that order**. All four change every round.

### The wording changes too, not just the numbers

Each of the four documents has **three phrasings**, one picked per round from the
same roll that picks the digits. The clipboard is always a security report — so
the prompt and the "found" line stay true — but it is a formal report one round,
a shift handover the next, and a night patrol sheet the one after.

That matters more than it sounds. With one fixed wording, a player who has read
the clipboard once knows to look at `SQUAD ASSIGNMENT` without reading the page,
and the investigation quietly becomes a lookup.

### The digits are hidden until collected

Every document is legible from the first second of the round, but the one field
that matters reads `████` until that clue is picked up. That is what
makes the order mean anything — with all four digits readable from across the
room, the counter and the sequence would be decoration.

### Where the text goes

| Prop | Has a TextLabel already? | What happens |
|---|---|---|
| `Note` | yes — `Post Note > SurfaceGui > TextLabel` | **your label is used**, only `.Text` is written |
| `House Number` | yes — `SurfaceGui > SIGN` | **your label is used**, only `.Text` is written |
| `Clipboard` | no | a SurfaceGui is made on the **Top** face |
| `ID Card` | no | a SurfaceGui is made on the **Front** face |

A label you built always wins — it is positioned against geometry the code has
never seen, and covering it would throw away the only work that knew where the
text should sit.

For the two that need one made: set the model's `PrimaryPart` to the flat part
you want the text printed on. If the face comes out wrong, change `face = "Top"`
to `"Front"` (or `Back`, `Left`, `Right`, `Bottom`) for that clue in
`src/shared/Config/PuzzleConfig.lua`.

**Do not put `FL_Slot` on a clue prop.** That is the instant-pickup path — any
survivor within 10 studs would pocket the document and destroy it.

---

## The counter

A card appears at the top of the screen for the whole team on Clinton:

```
CLUES  0/4
SEARCH THE BUILDING
```

It moves for everybody when anybody finds one, and whoever found it is named in
the subtitle line. At 4/4 it reads:

```
CLUES  4/4
HEAD TO THE CODE DOOR AT KFC
```

Out of order, it says which clue you actually need:

```
COLLECT THE SECOND CLUE FIRST — ROOM SIGN
```

It sits faded and brightens for a second and a half whenever it changes, and it
disappears the moment the vault opens — what happens after that is a horde, and
a clue counter is the least useful thing on the screen during one.

---

## What is in the room

Two more models, both **inert until the door opens** — no pickup attribute is
written and no tag is applied until then, so a player who clips through a wall
finds scenery.

```
Clinton
└── Puzzle
    ├── Clipboard          clue 1
    ├── House Number       clue 2
    ├── ID Card            clue 3
    ├── Note               clue 4
    ├── Flamethrower       loot — lying on the floor
    └── Dollar Stockpile   loot — interact once, pays the team
```

Same rule as the clues: put them in the `Puzzle` folder, or leave them where
they are in the loot room and the whole map is searched as a fallback. Names are
matched forgivingly. Don't tag anything.

### Flamethrower

Walk up to it and press interact. It goes into your **Primary** slot through the
ordinary floor-pickup path, so whatever you were carrying drops at your feet —
exactly like picking up any other weapon.

> **Not an ability slot.** The two ability slots hold permanent unlocks you buy
> and choose before a match — Shield, Turret, Field Medic, Cryo Blast, Airstrike.
> Putting a found weapon there would fight that system. Your description
> ("equip it, it's in your hand, you use it as a flamethrower") is a weapon, and
> Primary is where weapons live.

| | |
|---|---|
| Damage | 2 × 8 pellets at 600rpm — **160 dps point blank, 24 at range** |
| Range | 42 studs, useless past 40 |
| Fuel | 100, **no reserve** — ammo crates will not refill it |
| The point | **it sets things on fire** |

It is the worst direct-damage weapon in the game on purpose. The shotgun does
288 and the M249 does 373. What it does that they cannot is `ignites` — every
pellet that lands lights the target through the same `InfectedService:ignite`
the molotov uses, and a burning Common takes 25–45 a second until it dies
whatever you do next. Set a crowd alight and back away.

It cannot light a boss, for the same reason Incendiary Rounds cannot: an Apex
kept permanently alight is 150 free damage a second.

Never sold, never on an item pad, `floorOnly = true`. It exists in one place.

**It comes back.** Picking a weapon up destroys the world model, and a Clinton
round followed by another Clinton round does not reload the map — so the second
vault would have been empty. The first one seen is cloned aside and put back if
a later round cannot find it.

#### The held model — you do NOT need two copies

```
ServerStorage/                    (ReplicatedStorage works too)
└── Assets/
    └── Weapons/
        └── Flamethrower          ← one model, that is all
```

A first-person model **falls back to the world model automatically**. Put one
copy in `Assets/Weapons/Flamethrower` and it is used for the gun in your hands,
the gun on your back, and the gun other players see.

Only add `Assets/Viewmodels/Flamethrower` if you deliberately want a *different*
first-person model — lower-poly, or posed for a hand. The fallback goes one way
only: a Viewmodels entry is never used as the world model, because a prop built
for the first-person camera is the wrong thing for everyone else to look at.

The model in the loot room is separate from both. That one is the pickup lying
on the floor; these are what you hold once you have it.

#### Sounds — both wired

| Key | Id | Role |
|---|---|---|
| `FlamethrowerBurst` | `129504465599355` | Per shot, ten times a second. Quiet (0.38) and low priority, so it is a texture rather than a wall. |
| `FlamethrowerLoop` | `108835547890095` | A sustained bed that starts when the trigger goes down and stops when it comes up. |

Either alone would be wrong: ten bursts a second with no bed is a nailgun, and
a loop with no bursts has no attack. The loop is first-person only — teammates
hear the per-shot bursts through the ordinary world audio, because a looping
emitter per shooter is a stream nobody asked for.

It is stopped on every path that ends firing, not just the trigger release: a
dry tank, a weapon swap, going down, a menu opening. A loop is the one sound
that keeps playing if nobody tells it to stop, and a flamethrower still roaring
after you switched to a pistol is a bug that survives a whole playtest because
everyone assumes somebody else noticed it.

The burning it causes already has sound — that is the existing fire system the
molotov uses, and it needs nothing new.

### Dollar Stockpile

Interact once. **Everyone on the team gets 350 Dollars each** — not split, so
the team is not poorer for having four people in it. Then it is spent: the tag
comes off before a single dollar is paid, so two players reaching it on the same
frame cannot claim it twice.

---

## What happens when the code goes in

1. `ACCESS GRANTED`, the lock sound plays on the keypad.
2. The `Door` part fades out and stops colliding.
3. The whole team is paid in Dollars, and the map's item spawns restock.
4. **The horde comes.** `DirectorService:triggerPanicEvent` fires at the door —
   the same crescendo a panic trigger runs: three waves of 22 over 45 seconds,
   spawning around the vault rather than around the team.

A supply room you have to hold is a decision. A supply room you walk into is a
vending machine.

## Your existing KFC Code Door

**Its script and all twelve of its ClickDetectors are destroyed when the map
loads.** `MapService.sanitise` strips every `LuaSourceContainer`,
`ProximityPrompt` and `ClickDetector` out of every map, because the game has its
own interact system and a second one on the same geometry is a button nothing is
listening to.

So a revised version of that free-model script cannot work here — it would be
deleted before it ran. Nothing needs replacing, though:

- The **buttons stay as scenery**. B0–B9, Clear and Enter keep their decals.
- Walking up to the assembly and pressing the interact key opens a keypad panel
  drawn by the game, which works on mouse, gamepad and touch alike.
- The **`Door` part** fades out and stops colliding when the code is accepted.
  Fading rather than sliding, because a door built into a wall has nowhere to
  slide to.

The code is checked on the server. The client's keypad has never seen the
answer.

---

## Turning it off

`PuzzleConfig.Enabled = false`, or simply do not put the props in the map — a
map with no keypad logs one line and plays the round it always would.

---

## What the player experiences

They find a keypad on a locked door. They have no code.

Somewhere in the building there is a clipboard: **SQUAD ASSIGNMENT: 5**, signed
by M. HARPER. There is a sign on a door: **ROOM 83**. There is a security badge
on the floor belonging to **MARCUS HARPER**, whose **ID** is **2** — the same
person who signed the report.

Three numbers, six ways to arrange them. Then they find the procedure taped to a
wall:

```
Enter the credentials in this order:

  1. SQUAD
  2. ROOM
  3. OFFICER
```

**5832.** Next round it is a different squad, a different room, a different
officer and possibly a different order.

---

## Adding another puzzle later

`PuzzleConfig.Puzzles` takes one row per map, and `template` names a module in
`src/server/Level/Puzzles/`. A template answers three questions — what values to
roll, what those values spell, and what each prop should read — and nothing else.
The keypad, the anti-exploit, the door and the reward do not know what a squad
number is, so a symbol sequence or a breaker-switch puzzle is a new file and one
config row.
