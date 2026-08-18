# Fading Light — Architecture Contract

This is the binding spec. Every module listed here must exist at exactly the
path given, register under exactly the name given, and expose exactly the
methods given. Anything not in this document is an implementation detail and is
free to change.

## Rules that apply everywhere

1. **Never `require` another service.** Services are looked up at call time:
   ```lua
   local Registry = require(ReplicatedStorage.Shared.Util.Registry)
   Registry.get("GoreService"):processKill(model, context, result)
   ```
   Requiring `Shared.*` modules (Config, Enums, Util, Net) directly is correct
   and expected — those have no cycles.

2. **Every service module ends with**
   ```lua
   Registry.register("ServiceName", Service)
   return Service
   ```

3. **Lifecycle.** A service may define `Service:init()` and `Service:start()`.
   The bootstrap requires every module (which registers them), then calls every
   `init()`, then every `start()`. Do work that touches other services in
   `start()`, never at module scope.

4. **Networking.** Discrete events go through `Shared.Net.Remotes`. Continuous
   numbers go through attributes named in `Shared.Net.Attributes`. Never create
   a RemoteEvent by hand, and never poll a value over a remote that could be an
   attribute.

5. **Cleanup.** Anything with a lifetime owns a `Trove` and destroys it. No bare
   `:Connect` on a per-entity signal.

6. **The server is authoritative.** Clients predict visuals for responsiveness
   and send intent. The server decides all damage, all deaths, all spawns, and
   all inventory. Never trust a client-supplied damage number, target, or
   position without validating it against `GameConfig.HitValidation`.

7. **Luau style.** Tabs, `--!strict` where practical, `stylua.toml` governs
   formatting. Run `./scripts/check.sh` before you consider a file done.

8. **Comments explain *why*.** The configs are already heavily commented with
   design intent; match that voice in the systems. Do not narrate what the code
   obviously does.

## Shared types

Defined in `Shared/Types.lua`, required by anything that touches damage.

```lua
export type DamageContext = {
    attacker: Player?,          -- nil for environmental damage
    attackerModel: Model?,      -- the infected that did it, when not a player
    weaponId: string?,          -- Enums.Weapon
    damageType: string,         -- Enums.DamageType
    region: string,             -- Enums.HitRegion
    hitPart: BasePart?,
    hitPosition: Vector3,
    hitNormal: Vector3,
    direction: Vector3,         -- unit direction of travel
    distance: number,
    piercedCount: number,       -- bodies already passed through
    isFriendlyFire: boolean,
}

export type DamageResult = {
    dealt: number,              -- damage actually applied after all multipliers
    blocked: boolean,           -- true when the hit was rejected outright
    killed: boolean,
    overkill: number,           -- damage past zero health
    goreLevel: string,          -- Enums.GoreLevel
    severedPart: string?,       -- part name when goreLevel is Dismember
    remainingHealth: number,
}

export type HitRecord = {
    model: Model,
    part: BasePart,
    position: Vector3,
    normal: Vector3,
    distance: number,
    region: string,
    result: DamageResult,
}
```

## Server modules

Root: `src/server/` → `ServerScriptService.Server`

### `init.server.lua` — bootstrap
Creates collision groups, requires every service module in dependency-free
order, then runs `init()` on all, then `start()` on all. Wraps each call in
`pcall` and prints a clear error naming the service if one fails, so that one
broken system does not silently take the whole game down.

Collision groups to register with `PhysicsService`:
`Survivor`, `Infected`, `Debris`, `Gib`.
- `Debris` and `Gib` collide with `Default` only — never with `Survivor`,
  `Infected`, each other, or themselves.
- `Infected` collides with `Default` and `Survivor`, and **not with itself**
  (this is essential: a 46-strong horde that self-collides jams in doorways).

### `Audio/AudioService.lua` → `"AudioService"`
```lua
AudioService:playAt(def: SoundDefinition, position: Vector3, parent: Instance?): Sound?
AudioService:playOn(def: SoundDefinition, part: BasePart): Sound?
AudioService:playForPlayer(player: Player, def: SoundDefinition)
AudioService:stopAll()
```
Returns nil and warns exactly once per unconfigured id (`AudioConfig.isConfigured`).
Enforces `AudioConfig.Mix` voice limits. Never errors on a missing id.

### `Survivors/SurvivorService.lua` → `"SurvivorService"`
Owns survivor health, temp health, stamina, incapacitation, revive, death.
```lua
SurvivorService:spawnSurvivor(player: Player)
SurvivorService:getState(player: Player): string
SurvivorService:damage(player: Player, amount: number, ctx: DamageContext): DamageResult
SurvivorService:heal(player: Player, amount: number, temporary: boolean)
SurvivorService:incapacitate(player: Player, ctx: DamageContext)
SurvivorService:revive(player: Player, rescuer: Player?)
SurvivorService:kill(player: Player, ctx: DamageContext)
SurvivorService:setPinned(player: Player, by: Model?, kind: string?)
SurvivorService:getAliveSurvivors(): { Player }
SurvivorService:getSurvivorCharacters(): { Model }
SurvivorService:getTeamHealthFraction(): number   -- 0-1, drives Director item placement
SurvivorService:isIncapacitated(player: Player): boolean
SurvivorService.stateChanged: Signal   -- (player, newState, oldState)
SurvivorService.damaged: Signal        -- (player, amount, ctx)
SurvivorService.died: Signal           -- (player, ctx)
```
Writes every `Attributes.Player.*` field. Temp health decays on a heartbeat.
Applies `GameConfig.Survivor` verbatim — the incap/black-and-white rules are the
L4D ones and must not be simplified.

### `Survivors/InventoryService.lua` → `"InventoryService"`
```lua
InventoryService:getLoadout(player: Player): Loadout
InventoryService:giveWeapon(player, weaponId: string, ammo: number?, reserve: number?): boolean
InventoryService:giveItem(player, slot: string, itemId: string): boolean
InventoryService:getActiveWeapon(player): (string?, WeaponDefinition?)
InventoryService:setActiveSlot(player, slot: string): boolean
InventoryService:consumeAmmo(player, count: number): boolean
InventoryService:beginReload(player): boolean
InventoryService:useItem(player, slot: string): boolean
InventoryService:dropWeapon(player, slot: string): Model?
InventoryService.changed: Signal   -- (player, slot)
```
Mirrors everything into `Attributes.Loadout.*`. Handles shell-by-shell reloads
(interruptible: firing mid-reload keeps the shells already loaded).

### `Combat/DamageService.lua` → `"DamageService"`
**The single funnel for all damage in the game.** Nothing anywhere may modify a
Humanoid's health directly.
```lua
DamageService:applyDamage(target: Model, baseDamage: number, ctx: DamageContext): DamageResult
DamageService:applyExplosion(position: Vector3, radius: number, damage: number, ctx: DamageContext)
DamageService.damageDealt: Signal   -- (target, result, ctx)
```
Responsibilities, in order:
1. Reject if target is already dead or the context is invalid.
2. Multiply by `GameConfig.HitRegionMultipliers[ctx.region]`.
3. Apply `WeaponConfig.getFalloffMultiplier` and penetration falloff.
4. Apply `InfectedConfig.damageResistance` or survivor friendly-fire scaling.
5. Honour `headshotAlwaysKills` — a head region hit on a Common is lethal, full
   stop, regardless of the arithmetic. This rule is the game.
6. Route to `SurvivorService:damage` or `InfectedService:damage`.
7. On a kill, compute the gore level via `GoreService:evaluate` and call
   `GoreService:processKill`.
8. Fire `HitConfirmed` to `ctx.attacker` and `DamageTaken` to a damaged survivor.

### `Combat/BallisticsService.lua` → `"BallisticsService"`
Handles `Remotes.Event.FireWeapon`.
```lua
BallisticsService:resolveShot(shooter: Player, origin: Vector3, direction: Vector3, seed: number): { HitRecord }
```
- Rate-limits per `GameConfig.HitValidation.MaxShotsPerSecond`; over-rate shots
  are dropped silently, not errored.
- Validates the claimed origin is within `PositionTolerance` of the shooter's
  actual head position.
- Generates pellet directions with `ShotPattern.generate(direction, seed, ...)`
  — the same call the client made, so visuals and hits agree.
- Casts with `RaycastUtil.pierce`, treating live infected as pierceable up to
  `definition.penetration`.
- Consumes ammo through `InventoryService`, never directly.
- Replicates `WeaponFired` to everyone except the shooter, and `TracerEffect` /
  `ImpactEffect` in range.

### `Combat/MeleeService.lua` → `"MeleeService"`
Handles `Remotes.Event.SwingMelee` and `Remotes.Event.Shove`.
```lua
MeleeService:swing(player: Player, origin: Vector3, direction: Vector3)
MeleeService:shove(player: Player, origin: Vector3, direction: Vector3)
```
Melee sweeps a cone and damages up to `penetration` targets, with a strong
dismemberment bias. Shove deals no damage: it staggers everything in
`GameConfig.Shove.Arc`, frees a pinned teammate, and applies shove fatigue.

### `Combat/GoreService.lua` → `"GoreService"`
```lua
GoreService:evaluate(model: Model, ctx: DamageContext, overkill: number, maxHealth: number): (string, string?)
    -- returns (Enums.GoreLevel, severedPartName?)
GoreService:processKill(model: Model, ctx: DamageContext, result: DamageResult)
GoreService:ragdoll(model: Model, impulse: Vector3?)
GoreService:dismember(model: Model, partName: string, direction: Vector3, force: number)
GoreService:gib(model: Model, origin: Vector3, direction: Vector3)
GoreService:spawnBlood(position: Vector3, normal: Vector3, direction: Vector3, scale: number)
GoreService:getActiveCounts(): { ragdolls: number, gibs: number, limbs: number, decals: number }
```
Implements the scoring formula documented in `GoreConfig.Scoring` exactly.
Enforces every ceiling in `GoreConfig.Budget` by recycling the oldest object —
never by refusing to render. Ragdolling replaces `Motor6D`s with
`BallSocketConstraint`s and moves the model to the `Debris` collision group via
`RigUtil.makeDebris`. All visual gore is replicated with
`Remotes.fireInRange("GoreEvent", ...)` using `GoreConfig.Budget.CullDistance`.

### `Infected/InfectedService.lua` → `"InfectedService"`
```lua
InfectedService:spawn(kind: string, position: Vector3, cframe: CFrame?): Model?
InfectedService:despawn(model: Model)
InfectedService:damage(model: Model, amount: number, ctx: DamageContext): DamageResult
InfectedService:getAlive(kind: string?): { Model }
InfectedService:getCount(kind: string?): number
InfectedService:stagger(model: Model, direction: Vector3, duration: number)
InfectedService:ignite(model: Model, source: Player?)
InfectedService.spawned: Signal   -- (model, kind)
InfectedService.died: Signal      -- (model, kind, ctx)
```
Owns one shared update loop that ticks every brain. Do **not** give each
infected its own `RunService` connection — 46 heartbeat connections is how a
horde tanks the framerate.

### `Infected/InfectedBrain.lua`
```lua
InfectedBrain.new(model: Model, definition: InfectedDefinition): Brain
brain:update(dt: number)
brain:setTarget(target: Model?)
brain:destroy()
```
Common infected AI: pick the nearest reachable survivor, path toward them,
re-path on a budget (never every frame), attack on cooldown with a readable
windup, wander when idle. Uses `PathfindingService` with a fallback to direct
movement when a path fails, because a Common that stops moving is worse than a
Common that walks into a wall.

### `Infected/Specials/*.lua`
One module per special: `Hunter`, `Smoker`, `Boomer`, `Charger`, `Witch`, `Tank`.
Each returns:
```lua
{
    onSpawn = function(model: Model, brain: Brain) end,
    onUpdate = function(model: Model, brain: Brain, dt: number) end,
    onDeath  = function(model: Model, brain: Brain, ctx: DamageContext) end,
}
```
Behaviour is specified in the comments of `InfectedConfig`. Pins must always be
breakable by a teammate's shove or by enough damage — a pin the team cannot
answer is a bug, not difficulty.

### `Director/DirectorService.lua` → `"DirectorService"`
```lua
DirectorService:getPacingState(): string
DirectorService:getTeamIntensity(): number
DirectorService:addIntensity(player: Player, amount: number)
DirectorService:triggerPanicEvent(position: Vector3, waves: number?)
DirectorService:setDifficulty(name: string)
DirectorService:forceState(state: string)   -- debug only
DirectorService.pacingChanged: Signal       -- (newState, oldState)
```
Implements the intensity model and pacing machine from `DirectorConfig`
verbatim. Population is a *target to trickle toward*, never a dump. Broadcasts
`DirectorEvent` for music cues and writes `Attributes.Game.PacingState`.

### `Director/SpawnPlacement.lua`
```lua
SpawnPlacement.find(survivors: { Model }, options: SpawnOptions): (Vector3?, string?)
    -- returns (position, failureReason)
```
Honours every rule in `DirectorConfig.Spawning`: distance band, flow window,
out-of-sight requirement (checked against every survivor's camera cone AND a
line-of-sight raycast), and ground clearance.

### `Director/ItemPlacer.lua`
```lua
ItemPlacer:populateSection(sectionFolder: Instance)
ItemPlacer:spawnPickup(slot: string, itemId: string, position: Vector3): Model?
```
Chooses what to place from `DirectorConfig.ItemPlacement`, weighted by
`SurvivorService:getTeamHealthFraction()`.

### `Level/LevelService.lua` → `"LevelService"`
```lua
LevelService:getFlowDistance(position: Vector3): number
LevelService:getSurvivorFlow(): number         -- the furthest-ahead survivor
LevelService:getSpawnNodes(): { BasePart }
LevelService:getSafeRooms(): { Model }
LevelService:setObjective(text: string)
LevelService:onSafeRoomReached(room: Model)
LevelService.chapterChanged: Signal
```
Flow distance is measured along an ordered chain of `FlowNode` parts tagged with
`CollectionService`. Everything about the level is discovered from tags and
attributes so a hand-built map drops in without code changes:

| Tag | Meaning |
|---|---|
| `FL_FlowNode` | ordered by its `FL_Order` attribute; defines the level spline |
| `FL_SpawnNode` | a legal infected spawn point |
| `FL_ItemSpawn` | a candidate pickup location; `FL_Slot` attribute optional |
| `FL_SafeRoom` | a model containing a `Door` part; `FL_Index` attribute |
| `FL_PanicTrigger` | touching it starts a panic event |
| `FL_BossZone` | Tank/Witch may be placed here |

### `Assets/PlaceholderFactory.lua` → `"PlaceholderFactory"`
```lua
PlaceholderFactory:buildInfectedRig(kind: string): Model
PlaceholderFactory:buildWeaponModel(weaponId: string): Model
PlaceholderFactory:buildViewmodel(weaponId: string): Model
PlaceholderFactory:buildPickup(slot: string, itemId: string): Model
PlaceholderFactory:buildTestMap(): Model
PlaceholderFactory:ensureAssets()
```
Builds everything procedurally from parts, at runtime, in code — no `.rbxm`
files. Rigs are proper R15-named part hierarchies with `Motor6D`s so
dismemberment works on them exactly as it will on the user's real models.
Silhouettes must be distinguishable at a glance: a Tank is huge, a Boomer is
round, a Hunter is crouched, a Charger has one enormous arm.

`buildTestMap` produces a small but genuinely playable level — a start safe
room, three connected sections with cover and elevation, a panic-event
crescendo, and an end safe room — fully tagged per the table above.

## Client modules

Root: `src/client/` → `StarterPlayer.StarterPlayerScripts.Client`
Same Registry pattern, same lifecycle.

| Path | Registry name | Owns |
|---|---|---|
| `init.client.lua` | — | bootstrap |
| `Input/InputController.lua` | `"InputController"` | keybinds, forwards intent, exposes `Signal`s per action |
| `Weapon/WeaponController.lua` | `"WeaponController"` | fire loop, bloom, reload, ammo prediction, sends `FireWeapon` |
| `Weapon/ViewmodelController.lua` | `"ViewmodelController"` | first-person model, sway, bob, recoil kick, muzzle flash |
| `Effects/CameraController.lua` | `"CameraController"` | FOV, aim transition, shake, recoil, hit-stop |
| `UI/HudController.lua` | `"HudController"` | survivor panels, ammo, item slots, objective |
| `UI/CrosshairController.lua` | `"CrosshairController"` | spread-driven crosshair |
| `UI/HitmarkerController.lua` | `"HitmarkerController"` | hit / headshot / kill marks + damage numbers |
| `UI/PromptController.lua` | `"PromptController"` | interact prompts and hold progress |
| `UI/SubtitleController.lua` | `"SubtitleController"` | callouts and captions |
| `UI/OverlayController.lua` | `"OverlayController"` | vignette, incap/death screens, chapter cards, bile |
| `Effects/ImpactController.lua` | `"ImpactController"` | tracers, impact sparks, surface hits |
| `Effects/GoreController.lua` | `"GoreController"` | client-side blood, gibs, decals from `GoreEvent` |
| `Effects/OutlineController.lua` | `"OutlineController"` | teammate and item silhouettes |
| `Audio/MusicController.lua` | `"MusicController"` | Director-driven music cross-fades |

Client rules:
- The client may **predict** its own muzzle flash, tracer, recoil and ammo count
  immediately on click, then reconcile from the server. It must never predict a
  kill, a hit number, or a state change.
- Every `ScreenGui` is built in code (no `.rbxmx`), parented to `PlayerGui`,
  with `ResetOnSpawn = false` and the `DisplayOrder` from `UITheme.DisplayOrder`.
- All UI reads colour, size, font and timing from `UITheme`. No literal colours.
- One `RunService.RenderStepped` connection per controller, maximum.
