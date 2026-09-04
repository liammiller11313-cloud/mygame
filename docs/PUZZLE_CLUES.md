# The Vault Puzzle — what to put in the map

An optional side objective for **Clinton**. Four documents scattered around the
KFC, one keypad, one locked room. The code is different every round and is never
written down anywhere — it is spread across the four documents, and the fourth
one is what tells you how to arrange the other three.

Nothing about the KFC changes. No walls, no counters, no signage, no rebuild.
This is four props and a model you already have.

---

## How many models do I need?

**Four.** Everything else already exists.

| # | Object | Status | What it is |
|---|---|---|---|
| 1 | **Clipboard** | you supply | A clipboard with a sheet of paper on it, lying on a desk or counter |
| 2 | **Room Sign** | you supply | A small plaque or sign, screwed to a wall beside a door |
| 3 | **Badge** | you supply | An ID card, dropped on the floor or left on a surface |
| 4 | **Procedure** | you supply | A laminated sheet or taped-up notice, on a wall or a desk |
| — | **KFC Code Door** | **already in your map** | The free-model door assembly, used as-is |
| — | **Door** | **already in your map** | The part inside it that opens |

They can be anything — a Part with a flat face is enough. The game prints the
text onto them; you supply the object the text is printed on.

---

## Naming and placement

Name them exactly these, anywhere in the Clinton model:

```
Clipboard
Room Sign
Badge
Procedure
```

Naming is forgiving in the same way the ammo crate and medkit folders are: case,
spaces, punctuation and a trailing plural are all folded away, so `RoomSign`,
`room sign` and `Room Signs` are the same object.

**Optionally** put all four in a folder called `Puzzle` — the game looks there
first and then searches the whole map, so a tidy map stays tidy and an untidy one
still works. Your `KFC Code Door` stays exactly where it is, directly under
`Clinton`; it does not have to move into a folder.

You do **not** tag anything. The game finds them by name when a round starts and
tags them itself.

---

## What each prop needs

| Prop | Face the text lands on | Suggested size | Where it goes |
|---|---|---|---|
| Clipboard | **Top** | ~1.6 × 2.2 studs | Flat on a desk, counter or the manager's office |
| Room Sign | **Front** | ~2.5 × 1.5 studs | Beside the locked door, at head height |
| Badge | **Front** | ~0.9 × 0.6 studs | On the floor, a shelf, or beside a body |
| Procedure | **Top** | ~1.8 × 2.4 studs | Taped near the keypad, or in the back office |

- The face is set per prop in `PuzzleConfig` (`face = "Top"` / `"Front"`). If
  your model's readable surface points somewhere else, change that one word.
- **A Model needs a `PrimaryPart`.** That is the part the text is printed on. A
  single Part is fine too — the game wraps it for you.
- **Do not put `FL_Slot` on a clue prop.** That attribute is the instant-pickup
  path: any survivor within 10 studs would pocket the document and destroy it.
- Do not ship a `Script`, `ProximityPrompt` or `ClickDetector` inside them —
  see below.

---

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
