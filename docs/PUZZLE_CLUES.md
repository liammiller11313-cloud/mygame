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
