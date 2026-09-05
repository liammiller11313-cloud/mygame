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

## Health items

Three folders inside **each** map, one per item:

```
Zombieville/
    Medkits/
        Medkit 1 ... Medkit 11
    Pain Pills/
        Pain Pills 1 ... Pain Pills 9
    Adrenaline Shots/
        Adrenaline Shot 1 ... Adrenaline Shot 7
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
in your map rather than building its own. Change the prop in the map and the
whole game changes with it; there is no second copy to keep in sync.

> If a folder is missing or misnamed, the server says so by name at boot and
> lists what folders the map *does* have. Pills and adrenaline fall back to a
> built-in model so the Director's item flow keeps working; a **medkit does
> not** — no map kit means no kit, because your model is the only medkit the
> game has.

The whole contract lives in `MapConfig.MapItems`, one entry per family, if you
want a fourth.

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
