# Maps and Ammo Crates

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

Runs automatically as a round ends, underneath the scoreboard, for 20 seconds.
Click a card or press **1** / **2**. You can change your vote until the clock runs
out.

A tie breaks **away** from the map you just played — an even split that replays
the same map reads as a vote that was never counted.

The winner is cloned into storage the moment it's decided, while the scoreboard
is still up, so the actual swap is nearly instant.

Tuning is in `MapConfig.Vote`.
