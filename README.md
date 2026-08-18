# Fading Light

A Left 4 Dead 2-inspired four-player co-op zombie shooter for Roblox.

Built quality-first: one campaign's worth of systems, done properly, rather than a
broad shallow framework. The killing is the product — hit registration, gore,
feedback and pacing get the attention, and everything else serves them.

---

## What's in here

| System | What it does |
|---|---|
| **AI Director** | Watches how hard the team is being pressed and deliberately backs off, so the next horde lands on a team that just had time to breathe. Pacing, population, special scheduling, boss placement and item placement all flow from it. |
| **Ballistics** | Hitscan with per-region damage (4× headshots), penetration, distance falloff, per-shot bloom and deterministic shotgun spread that guarantees tracers land where pellets land. |
| **Gore** | Ragdolls, dismemberment with correct limb chains, gibbing, three-layer blood, wall decals, and hit-stop on kills. |
| **Survivors** | The full L4D health model: temp health that decays, incapacitation, bleed-out, revives, black-and-white, ledge hangs, friendly fire. |
| **Infected** | Common horde plus Hunter, Smoker, Boomer, Charger, Witch and Tank, each with its own behaviour and counter. |
| **UI** | A Left 4 Dead HUD — four survivor bars bottom-left, ammo bottom-right, teammate silhouettes through walls, and almost nothing else. |

---

## Getting it running

### 1. Install the toolchain

The project syncs into Studio with [Rojo](https://rojo.space). The pinned tool
versions are in `rokit.toml`:

```bash
# Install Rokit (the toolchain manager), then:
rokit install
```

If you'd rather not use Rokit, install Rojo 7.5+ any way you like — the
[Rojo install docs](https://rojo.space/docs/v7/getting-started/installation/)
cover Aftman, Foreman, cargo and the standalone binaries.

You also want the **Rojo plugin for Roblox Studio**, which you can install from
Studio's plugin marketplace or with `rojo plugin install`.

### 2. Sync into Studio

```bash
rojo serve
```

Open Roblox Studio, open (or create) a place, click the Rojo plugin button, and
hit **Connect**. The whole `src/` tree appears under the right services and stays
live-synced as you edit.

To build a `.rbxl` without Studio in the loop:

```bash
rojo build -o FadingLight.rbxlx
```

### 3. Press play

The server bootstrap builds a grey-box test map, spawns you with a loadout, and
starts the Director. You should be able to shoot a zombie within a few seconds of
pressing Play. Use **Play Solo** for a quick look; use **Team Test** with 2–4
players to see the co-op systems (revives, silhouettes, the Director reacting to
the team) actually do their thing.

---

## Dropping in your own models

Everything ships with procedurally-built grey-box placeholders so the game is
playable today. Replacing them is deliberately a drop-in, not a refactor.

### Zombie models

Put an R15 rig in `ReplicatedStorage.Assets.Infected.<Kind>` — `Common`,
`Hunter`, `Smoker`, `Boomer`, `Charger`, `Witch`, `Tank`. It needs:

- Standard R15 part names (`Head`, `UpperTorso`, `LeftUpperArm`, …)
- `Motor6D` joints between them — **this is what dismemberment cuts**, so a rig
  welded together instead of jointed won't come apart
- A `Humanoid` and a `HumanoidRootPart`

Stats, speeds and behaviour come from `src/shared/Config/InfectedConfig.lua`, not
from the model.

### Weapon models

Put them in `ReplicatedStorage.Assets.Weapons.<WeaponId>` and the first-person
version in `ReplicatedStorage.Assets.Viewmodels.<WeaponId>`, named to match the
keys in `src/shared/Config/WeaponConfig.lua`. Each needs:

- A `Handle` part
- A `Muzzle` attachment at the barrel tip (muzzle flash and tracers originate here)

Adding a **new** weapon is: add a key to `Enums.Weapon`, add its stat block to
`WeaponConfig`, drop the model in. No new code.

### Maps

Build your level however you like, then tag it with `CollectionService`:

| Tag | Meaning |
|---|---|
| `FL_FlowNode` | Ordered by an `FL_Order` attribute. Defines the level's spline — this is how the Director knows what's "ahead of" the team. |
| `FL_SpawnNode` | A legal infected spawn point. Put these out of the main sightlines. |
| `FL_ItemSpawn` | A candidate pickup spot. Optional `FL_Slot` attribute to constrain what appears. |
| `FL_SafeRoom` | A model containing a `Door` part, with an `FL_Index` attribute. |
| `FL_PanicTrigger` | Touching it starts a panic event. |
| `FL_BossZone` | A Tank or Witch may be placed here. |

No hard-coded positions anywhere. A tagged map works with zero code changes.

### Sounds

**Every sound id in `src/shared/Config/AudioConfig.lua` is intentionally empty.**
Audio asset ids are account-specific and can't be guessed — a made-up number
either fails to load or pulls in somebody else's unrelated audio. So the game
runs silent until you fill them in, warning once per missing id and then staying
quiet.

Upload or pick your audio in Studio and paste the ids in. If you're doing it a
few at a time, this is the order that buys the most:

1. **Weapon fire** — by an enormous margin the sound you hear most
2. **Flesh impact** — the confirmation that you connected
3. **Gib / dismember** — the payoff
4. **Special infected calls** — in L4D these *are* the early-warning system
5. Everything else

---

## Tuning the game

Every balance number lives in `src/shared/Config/`, heavily commented with the
reasoning behind it. Nothing is hard-coded elsewhere.

| File | Governs |
|---|---|
| `WeaponConfig.lua` | Damage, RPM, spread, recoil, reloads, falloff, gib bias |
| `InfectedConfig.lua` | Health, speeds, attacks, awareness, spawn cost, gore |
| `GameConfig.lua` | Survivor health model, hit regions, shove, hit validation |
| `DirectorConfig.lua` | Intensity, pacing, population, specials, bosses, difficulty |
| `GoreConfig.lua` | The gore scoring formula, dismemberment, gibs, blood, budgets |
| `UITheme.lua` | Every colour, font, size and timing in the interface |
| `AudioConfig.lua` | Sound ids and mixing |

A few worth knowing about:

- **`GameConfig.HitRegionMultipliers.Head = 4.0`** and
  **`InfectedConfig.Common.headshotAlwaysKills = true`** are what make aiming the
  whole skill expression. A horde without these is an HP sponge.
- **`DirectorConfig.Pacing`** min/max dwell times control the whole rhythm of the
  game. Shortening `Relax` makes it relentless; lengthening it makes it tense.
- **`GoreConfig.Scoring`** decides when a body ragdolls, loses a limb, or comes
  apart entirely. `GibScore` is the dial for how visceral the game is.
- **`GoreConfig.Budget`** ceilings are not optional — they're what keep a
  46-zombie horde from tanking the framerate.

---

## Development

```bash
./scripts/check.sh          # format + syntax-check every Luau file
./scripts/check.sh --check  # verify without writing
```

Architecture, module contracts and the rules the codebase follows are in
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).
