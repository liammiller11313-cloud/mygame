# Maps, Items and Ammo Crates

## Where the maps go

```
ServerStorage/
└── Maps/
    ├── Zombieville
    └── Clinton
```

**Not Workspace.** Only the map being played is in the world at any moment —
that's what makes swapping between rounds fast, because the replacement is
already assembled in memory and loading it is a reparent rather than a rebuild.

The model name must match exactly: `Zombieville` and `Clinton`, matching the ids
in `src/shared/Config/MapConfig.lua`.

> If you leave a map in `Workspace.Maps`, the game moves it to `ServerStorage.Maps`
> for you on startup and prints a line saying so. That's a convenience for a map
> you're mid-way through building, not the intended home — leaving it there would
> mean the world contains two of every map.

### Adding a third map later

One entry in `MapConfig.Maps` and a model in `ServerStorage.Maps`. No code. It
joins the vote automatically.

### Tagging a map

**Run `studio-scripts/TagMap.lua` in the Studio command bar. That is the whole
job.** It reads the geometry and writes every tag the level system needs.

Until a map is tagged, the game runs entirely on fallbacks: the Director cannot
tell what is ahead of the team so it spawns purely by distance from whoever it
can see, items scatter instead of stocking the route, and survivors start in a
ring wherever the fallback picks rather than where a round should begin. It is
playable and it is noticeably worse.

What the script does: it casts a downward ray over a grid across the map, keeps
the cells with standing room, finds the largest connected walkable region, and
measures the longest route across it. On a street map that route lands on the
street, because the buildings were never walkable cells. Everything else is
placed relative to that route.

| Tag | Where it puts them |
|---|---|
| `FL_FlowNode` | along the route, ~42 studs apart, numbered with `FL_Order` |
| `FL_SurvivorSpawn` | four spots at one end of it |
| `FL_SpawnNode` | 22–110 studs off the route — alleys, side streets, back rooms |
| `FL_ItemSpawn` | 6–55 studs off it, spread along its length, flush with the floor |

Everything it creates goes in one `FL_Nodes` folder inside the map. Re-running
deletes the previous folder first, so it is safe to run twice, and deleting that
folder undoes it completely. It never touches, moves or modifies a part of your
build.

**Which end the round starts at** is the one thing the geometry cannot tell it.
It pins the start to the end of the route nearest the world origin and prints
both endpoints when it runs — so if the team spawns at the wrong end of the
street, set `REVERSE_ROUTE = true` at the top of the script and run it again.
The choice is deterministic either way, so an unrelated edit to the map will
never quietly move your spawn to the other side of it.

Treat it as a first pass, not a level designer. Open `FL_Nodes/Flow`, look at
where the chain went, and drag nodes that landed somewhere silly — the order
comes from `FL_Order`, not from position, so moving one can never break the
chain. Same for the spawn nodes: the script only knows "off the route", it does
not know that one of those alleys is visible from the whole street.

`FL_BossZone` and `FL_PanicTrigger` are not written automatically. Both are
authored decisions — where the Witch should be, which doorway starts a panic
event — so tag those two by hand when you want them.

---

## Naming a surface nothing may spawn on

A raycast cannot tell a floor from a ceiling. Both are flat, both have an upward
normal from the side you hit them, and **the top of a wall is the best-looking
floor in any map** — which is how a Tank ended up standing on the roof of the
Backrooms.

The Director has geometric guards for this (a height band, an overhead-cover
test, a check that the floor belongs to the loaded map) and every one of them is
an *inference*. Naming the thing is the answer that cannot be fooled.

**Name a part, or any model it sits inside, one of these and nothing will ever be
spawned on it:**

| Name | Also matches |
|---|---|
| `Ceiling` | `ceilings`, `CEILING`, `Ceiling_01` |
| `Celing` | the one-E spelling, because a real map in this game uses it |
| `Roof` | `roofs`, `Roof 2` |
| `Wall` | `Walls`, `wall`, `WALLS` |

Case, spaces, punctuation and a single trailing `s` are all folded away first —
the same rule item folders are matched by.

### It checks the ancestors, which is the part that matters

The Backrooms keeps its geometry in a model called **`Walls`** holding models
called **`section`**, whose parts are named whatever the artist felt like.
Testing the part alone would answer nothing. Testing the part *and every model
above it up to the map root* answers all of them from the single `Walls` entry —
so you do not have to rename anything inside it.

```
Backrooms
  Floor          <- bodies stand here
  Celing         <- nothing is spawned on top of it
  Walls          <- and nothing on anything inside it, however deeply nested
    section
    sections
  wall, wall, wall
```

### What it does not do

It does not change collision and it does not stop a survivor **walking** onto
something they can reach. It answers one question — *may a spawn be placed
here* — which was previously being answered by guessing. Make `Floor` collidable
and both zombies and survivors will stand on it; that half is Roblox's, not the
game's.

A map that names nothing still works. It gets the geometric guards and nothing
worse.

## Items in the map

Five folders inside **each** map, one per item:

```
Zombieville/
    Medkits/
        Medkit 1 ... Medkit 11
    Pain Pills/
        Pain Pills 1 ... Pain Pills 9
    Adrenaline Shots/
        Adrenaline Shot 1 ... Adrenaline Shot 7
    Molotovs/
        Molotov 1 ... Molotov 6
    Pipe Bombs/
        Pipe Bomb 1 ... Pipe Bomb 7
    Hazardous Wastes/
        Hazardous Waste 1 ... Hazardous Waste 7
```

**You don't tag anything.** Same rule as the crates — the game finds each folder
by name when the map loads and does the rest. Naming is forgiving: `Medkit 3`,
`Medkit3` and `medkit 3` all work, and `Pain Pills`, `pain pills` and `PainPill`
all find the same folder. The counts above are what you have; nothing enforces
one, and a model with no number on the end just keeps its place in the folder.

**They glow through walls when you are near one.** Every pickup carries the
`FL_Pickup` tag and the client outlines the nearest few in item colour — which
matters most for the small ones, since a pill bottle on a dark floor has no light
of its own. (Until 2026-09-05 this only worked for items the Director dropped:
the scan looked at the top of `Workspace` and a map's items are three levels down
inside the map model, so the ones placed by hand were the only ones in the game
with no outline on them.)

**Your models are the game's models.** These folders are not only *where* the
items are — they are what the items *look like*, everywhere. When the Director
drops pills on an item pad partway through a wave, it copies the model standing
in your map rather than building its own. A molotov in a hand, lying on a pad,
and turning over in the air is the same object all three times. Change the prop
in the map and the whole game changes with it; there is no second copy to keep
in sync.

> If a folder is missing or misnamed, the server says so by name at boot and
> lists what folders the map *does* have. Pills and adrenaline fall back to a
> built-in model so the Director's item flow keeps working; a **medkit does
> not** — no map kit means no kit, because your model is the only medkit the
> game has.

The whole contract lives in `MapConfig.MapItems`, one entry per family, if you
want a fourth.

### How throwables behave

Molotovs and pipe bombs are placed in the level rather than handed out by the
Director, and that is the point: a throwable on a shelf is a reason to go and
look at the shelf. It is the cheapest thing a level can do to make its own rooms
worth walking into.

- **Walk up and take it.** It fills your Throwable slot and you can see it in
  your hand — yours and everyone else's.
- **Swap freely.** Picking up a pipe bomb while carrying a molotov drops the
  molotov where you are standing, as your own model, for somebody else to find.
- **Throw it** on your normal throw input. The object turning over in the air is
  the same model.
- **The spawn point refills after it is thrown** — not after it is picked up.
  Forty seconds for molotovs and pipe bombs, sixty for hazardous waste. Faster
  than a medkit and there are more of them, because throwables are meant to be
  *spent*: one somebody is saving for later is one doing nothing.

### The three of them do different jobs

| | |
|---|---|
| **Pipe bomb** | draws the horde to it, then kills what came |
| **Molotov** | denies a place with fire |
| **Hazardous waste** | draws the horde to a place and *holds* it there |

The waste is the one you throw **before** the wave rather than at it. Its leak
runs for fifty seconds, so it is still pulling when the thing you put it down
for arrives: bait a corridor you are not defending, buy a route to the safe
room, or feed a crowd into a molotov you already threw. It coats nobody,
deliberately — a leak that turned the nearest survivor into the target would be
doing the Boomer's job, and worse than the Boomer does it.

Sixty seconds to respawn rather than forty, because a fifty-second zone on a
forty-second clock is one player keeping a permanent leak running somewhere on
the map.

> **The bile jar is gone.** The waste replaced it rather than joining it: both
> put a puddle on the floor that the horde walks to, and two items that do that
> are one item and a copy of it. Its other half — coating a survivor so the
> horde comes for the *person* — belongs to the Boomer, which still does it.

> `Assets/Throwables` still works as a fallback for a throwable no map places.
> Every throwable has a map folder today, so nothing uses it and the game
> creates no empty folders in there.

### How medkits behave

- **Walk up and take it.** Instant, like any other pickup — no hold. It lands in
  your Health slot and shows in the hotbar.
- **It rides on your back**, visible to the whole team. That is the point: in
  Left 4 Dead the most useful thing you know about a teammate is whether they
  still have a kit, and you learn it by looking at them.
- **Use it** (H on desktop, or press the medkit slot again on a controller or
  phone) for a five-second heal worth 80% of the health you are missing — so the
  kit is worth most to whoever is worst off.
- **The spawn point refills thirty seconds after the kit is spent**, not thirty
  seconds after it is taken. Carrying an unused kit does not quietly restock the
  map behind you. A faint ghost is left where it was, so a player who has learned
  the map can plan around a kit that is not there yet.
- If the person carrying it **disconnects**, the spawn point refills on the same
  clock rather than the map being one medkit poorer for the rest of the round.

The prop on the back is scaled down from your own model, and anything larger than
`MapConfig.Medkits.CarryMaxSize` is scaled to fit rather than by the fixed factor
— the supplied models are built to be read on the floor, not worn, and a big one
would otherwise become a wardrobe on somebody's shoulder. `CarryOffset` in
`MapConfig` moves it if it sits wrong on your rig.

Only the medkit rides on a back. A pill bottle on someone's shoulder would be
three pixels, and the point of carrying a kit visibly is that the team can read
it across a room.

### How pills and adrenaline behave

Both go in the **Pills** slot — you can carry one, alongside a medkit — and both
are taken instantly and used with the same button.

**Pain pills** are a buffer: 50 temporary health that drains slowly. It is time,
not healing, and it is what a hurt team takes when there is no kit.

**Adrenaline is not a smaller pill bottle.** It is 25 temporary health that
drains almost three times as fast, and the health is the least of it — see
`docs/ADRENALINE.md`. Everything else it does is about the next fifteen seconds.

They refill on a slower clock than a medkit (45 and 55 seconds against 30) and
only once the item is actually **used**. Dropping or swapping one leaves it lying
in the world, so refilling on those would print bottles.

---

## Ledges you can survive

Tag a Part **`FL_LedgeCatch`** and lay it along the lip of a drop. A survivor who
falls through it grabs the edge instead of dying.

```
Zombieville/
    <a part tagged FL_LedgeCatch, along the balcony edge>
```

No attributes, no orientation to get right, no script. The game makes the part
invisible and completely inert on load — no collision, no queries — so a catch
volume can never block a shot, a shove or a prompt.

### Sizing it

**The top of the box is the lip.** Put it level with the floor you can walk off
and let it hang down over the edge. A survivor is only caught once they are
*below* that line, which is what stops the volume grabbing people who jump near
the edge — and they will, constantly, because the edge is where the fighting is.

**Reach out, not just down.** Depth costs nothing: the check samples the path a
body actually took, so even a shallow box catches a fall from any height. What a
shallow box misses is a fast one going *sideways*. Modelled against every way to
leave a ledge:

| Net reaches out… | stepped off | sprinted off | charged off at 44 | launched by a Tank |
|---|---|---|---|---|
| 6 studs | caught | caught | **missed** | **missed** |
| 16 studs | caught | caught | caught | caught |

**Cover the whole edge.** Length along the lip is the easy one to get right.

### What happens

- **They hang** just below the lip, facing back the way they came. They cannot
  move, shoot or be shot.
- **A teammate pulls them up** — a one-second hold, the same prompt shape as a
  revive. They land on the solid ground behind the lip.
- **Or they let go** after sixty seconds, or sooner if the slow bleed finishes
  them. That **incapacitates** rather than kills, and costs one of the three
  lives a round allows.
- Either way they end up **at the edge, not at the bottom**. Incapacitating
  someone mid-air over the drop they just fell down would be a body nobody can
  reach and a timer the team can only watch.

The numbers are `GameConfig.Survivor.LedgeHangTime`, `LedgeHangDamagePerSecond`
and `LedgePullTime`; the geometry is `MapConfig.Ledges`.

> Mark the ones you want to be a moment. A ledge somebody has to be pulled off
> only means something if most drops still simply kill you.

---

## Ammo crates

Inside **each** map, put a folder called `Ammo Crate`:

```
Zombieville/
└── Ammo Crate/
    ├── Ammo Crate 1
    ├── Ammo Crate 2
    ├── Ammo Crate 3
    ├── Ammo Crate 4
    ├── Ammo Crate 5
    └── Ammo Crate 6
```

Same again inside `Clinton`.

**You don't tag anything.** The game finds the folder by name when the map loads
and tags the crates itself. Naming is forgiving — `Ammo Crate 3`, `AmmoCrate3`
and `ammo crate 3` all work, and the number on the end becomes the crate's index.

Each crate can be a **Model** or a single **Part**. A lone part gets wrapped in a
Model automatically.

### How they behave

- Walk up, **hold E**. Takes 2.5 seconds — long enough to be a real commitment
  in the middle of a fight.
- Refills your primary's reserve completely and tops the magazine up, so you walk
  away actually ready rather than needing to reload immediately.
- Then it's **gone for 165 seconds**, leaving a translucent grey ghost behind so
  the spot still reads as a resupply point you can plan around.
- A crate **refuses to be spent** if you're already full. Losing a resupply to a
  walk-past would be infuriating.
- All six reset between rounds, so a new round never opens with half its resupply
  still on cooldown.

Placing them is a real design decision: six crates and a 165-second cooldown is
what stops a team camping one corner. Spread them so that holding any single
position runs you dry.

### Tuning

`MapConfig.AmmoCrates` — respawn time, hold duration, how much a crate gives,
whether it leaves a ghost.

---

## The map vote

It appears at exactly two moments, and nowhere else.

**After a round ends.** It draws over the scoreboard rather than replacing it:
the scoreboard is what you are reading, and the vote is a second thing to do
while you read it. That is why the vote sits above the menu in the display order.

**Not during the lobby.** The first round of a fresh server uses `DefaultMap`.

That is `MapConfig.Vote.OnFreshServer`, and it is off for a specific reason worth
knowing before turning it on: the lobby countdown is *not* a signal that anybody
chose anything. `MatchmakingService` counts a player who has picked nothing as a
vote for the default mode, so the countdown starts within a second of the first
join. Every second of it is a second the player is sitting on the main menu
reading the mode list — so a vote during the countdown is a vote thrown over the
menu, which is exactly what it is not supposed to be.

If a vote's round never starts — the last player leaves, matchmaking cancels —
the card closes itself after eight seconds rather than waiting for a map load
that is never coming.


Runs automatically as a round ends, underneath the scoreboard, for 20 seconds.
Click a card or press **1** / **2**. You can change your vote until the clock runs
out.

A tie breaks **away** from the map you just played — an even split that replays
the same map reads as a vote that was never counted.

The winner is cloned into storage the moment it's decided, while the scoreboard
is still up, so the actual swap is nearly instant.

Tuning is in `MapConfig.Vote`.
