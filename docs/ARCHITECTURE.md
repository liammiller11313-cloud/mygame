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
|  | | *ammo is PREDICTED here. Anything drawing a count reads `getAmmo()`/`getWeaponId()` for the slot `getActiveSlot()` reports, and repaints on `ammoChanged`/`weaponChanged`. Reading `LA.PrimaryAmmo` for the gun in hand puts the counter a round trip behind the muzzle flash — and a local Studio server has no round trip, so it looks perfect while you test it.* |
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
  `docs/LOOK.md` is the map of which number does what.
- One `RunService.RenderStepped` connection per controller, maximum.

---

# Addendum — round-based modes, matchmaking, atmosphere

This supersedes the campaign/safe-room model in the sections above. **There are no
safe rooms and no chapters.** A round is a fixed 17 minutes of holding out against
seven escalating waves, defined in `Shared/Config/GameModeConfig.lua`.

That changes what the Director is *for*, but not what it *does*. The wave schedule
decides WHEN pressure happens; the Director still decides WHAT and HOW MUCH inside
each wave, still reads team intensity, still refuses to spawn in someone's field of
view, and still places items based on how badly the team is hurting. It works
inside a wave's budget instead of inventing its own pacing.

## New server modules

### `Round/RoundService.lua` → `"RoundService"`
Owns the Classic round lifecycle. Replaces LevelService's campaign loop entirely.
```lua
RoundService:startRound(mode: string)
RoundService:endRound(outcome: string)          -- Enums.RoundState
RoundService:getState(): string
RoundService:getWaveIndex(): number
RoundService:getWave(): WaveDefinition
RoundService:isBreather(): boolean
RoundService:getTimeRemaining(): number          -- to the end of the whole round
RoundService:getWaveTimeRemaining(): number      -- to the end of the current phase
RoundService:getElapsed(): number
RoundService.waveChanged: Signal                 -- (index, definition)
RoundService.phaseChanged: Signal                -- (isBreather, index)
RoundService.roundEnded: Signal                  -- (outcome)
```
- Drives `Attributes.Game.RoundState`, plus new attributes `FL_WaveIndex`,
  `FL_WavePhase` ("Prep" | "Active" | "Breather" | "Over"), `FL_RoundEndsAt`,
  `FL_WaveEndsAt` (both absolute `workspace:GetServerTimeNow()` stamps so the
  client can render a smooth countdown with no per-frame remote traffic).
- Applies `GameModeConfig.Classic`: prep window, per-wave population and spawn-rate
  scaling handed to the Director, boss releases at wave start, breather restock and
  dead-player respawn.
- Team wipe ends the round immediately. Surviving wave 7 is a Victory.
- Announces via `DirectorEvent` and `Subtitle` — **`Subtitle` currently has no
  server sender at all; RoundService becomes its producer.**

### `Round/VersusService.lua` → `"VersusService"`
Splits the server as evenly as possible into survivors and playable special
infected, per `GameModeConfig.Versus`.
```lua
VersusService:startVersus()
VersusService:getTeam(player: Player): string    -- Enums.Team
VersusService:requestSpawnAs(player: Player, kind: string): boolean
VersusService:getAvailableKinds(player: Player): { string }
VersusService:swapTeams()
VersusService:getScores(): { [string]: number }
```
Infected players spawn as ghosts for `InfectedGhostTime`, pick a spot, then
materialise. Respawn on `InfectedRespawnTime`. `InfectedMaxSameKindAlive` forces
the team to coordinate rather than all picking Tank.

### `Round/MatchmakingService.lua` → `"MatchmakingService"`
One place, one round per server. Uses `MemoryStoreService` for a cross-server
browser and `TeleportService` to move players.
```lua
MatchmakingService:requestMode(player: Player, mode: string)
MatchmakingService:getLobbyState(): { mode: string, countdown: number, players: number }
MatchmakingService:advertise()
```
- If this server is idle, or already running the requested mode and is inside
  `JoinInProgressUntilWave`, the player joins here.
- Otherwise query the MemoryStore sorted map for a server running that mode with
  room, and `TeleportToPlaceInstance`.
- If none exists, this server claims the mode and starts a lobby countdown.
- **Must degrade gracefully.** MemoryStore is unavailable in Studio and throws;
  wrap every call in `pcall` and fall back to "run it on this server". A developer
  pressing Play must always get a round, never a matchmaking error.

### Infected animation

Two systems, and which one runs depends on what the rig shipped with.

| | Owner | Drives | When |
|---|---|---|---|
| `Server/Infected/InfectedAnimator` | server | `AnimationTrack`s | the rig harvested ids, **or** `AnimationConfig` supplies them |
| `Client/Effects/InfectedPoseController` | client | `Motor6D.Transform` | neither did |
| `Server/Infected/InfectedBrain:_setSwingPose` | server | `Motor6D.C0` | attack windup, always |

Animation sources are tried rig-first, then `Shared/Config/AnimationConfig`, then
procedural. A rig that shipped its own walk keeps it — it knows its own
proportions better than a generic package does — and `AnimationConfig` only fills
the roles left over.

`AnimationConfig` is keyed **by rig**, not by kind: R6 and R15 each have a
complete set, so every body in the roster gets real clips and the procedural
poser is now the fallback for a rig that is neither. A per-kind override exists
for the day one kind should move differently, and is still checked against the
rig before it is used.

The engine resolves a joint as `C0 * Transform * C1:Inverse()`, which is what
lets the brain's windup pose and a walk cycle coexist without either knowing
about the other.

Two rules:

- **A continuous gait must never be driven from the server.** `Motor6D.C0`
  replicates, which is why the brain can pose an attack windup for two property
  writes — but forty-six bodies × eight joints × sixty frames is a quarter of a
  million replicated writes a second. Discrete poses on the server, continuous
  motion on the client.
- **Every animation set declares the rig it addresses.** A Roblox animation is a
  keyframe sequence addressed to named joints: an R6 clip on an R15 rig loads,
  reports itself as playing, and moves nothing. That is worse than doing nothing,
  because `InfectedPoseController` stands down for any body with tracks playing —
  so the body ends up animated by neither, which looks exactly like the T-pose
  bug the whole system exists to fix. `AnimationConfig.rigOf` reads the model's
  actual joints rather than `Humanoid.RigType`, which hand-built rigs routinely
  get wrong.
- **Never assume a joint's hinge axis.** `Transform` is applied inside `C0`'s
  frame, and R6 shoulders carry a ±90° yaw in theirs while R15 shoulders carry
  none — so `CFrame.Angles(theta, 0, 0)` swings an R15 arm forward and an R6 arm
  out sideways. Derive it: `C0.Rotation:Inverse() * Vector3.xAxis` is the
  parent's right axis in joint space, and it is the correct hinge on any rig.

### `Level/MapItemService.lua` → `"MapItemService"`

Owns every item folder in the live map — `Medkits`, `Pain Pills`,
`Adrenaline Shots`, `Molotovs` and `Pipe Bombs`, declared in
`MapConfig.MapItems`. Dresses each model as a
pickup where it stands and refills that spot once the item it produced is
**spent**. Listens to `InventoryService.pickedUp` and `.itemConsumed` — not
`.changed`, which cannot tell a spend from a drop, a swap or a death, and
refilling on those would print items.

It is also where the ART for these three comes from: `getTemplate(itemId)` hands
back the map's own model, and both `PlaceholderFactory` (pads) and
`CarryVisualService` (backs) use it, so there is no second copy to keep in sync.

### `Level/LedgeService.lua` → `"LedgeService"`

Turns a fall off an `FL_LedgeCatch` volume into a hang. Owns the geometry and
nothing else: it works out where the lip is, which way the survivor was going and
where the solid ground behind it is, then hands all three to
`SurvivorService:ledgeHang`. That service owns the state, the clock and the body;
this one knows nothing about survivors beyond "upright" and "falling".

The test is **arithmetic against the cached box, not a raycast**, and that is the
whole reason the volumes can be `CanQuery = false`: an invisible part a ray can
hit is one a *bullet* can hit, and a wall that eats shots fired over a balcony
would be a worse bug than the one this fixes. It samples the line between each
body's last position and its current one, so a fast fall cannot tunnel through a
shallow net — endpoints alone miss a 4-stud net from 82 of 115 start heights.

### `Survivors/CarryVisualService.lua` → `"CarryVisualService"`

Mirrors the Health slot onto the character, so the kit is visible on a survivor's
back to the whole team.

### `Level/AtmosphereService.lua` → `"AtmosphereService"`
The game is called Fading Light. Make that literal: the round opens at dusk and is
pitch dark by wave 7, driven off `RoundService:getElapsed()` rather than a free-
running timer, so the light level always reads as *how far through the round you
are*.
```lua
AtmosphereService:setPhaseFromRound(elapsed: number, total: number)
AtmosphereService:flash(duration: number, intensity: number)   -- explosions, lightning
AtmosphereService:setBossMood(active: boolean)
```
Interpolates `Lighting.ClockTime`, `Ambient`, `OutdoorAmbient`, `Brightness`,
`FogEnd`, `ExposureCompensation` and an `Atmosphere` instance's `Density`/`Haze`.
Tune it dark and cold. Keep `FogEnd` short enough to hide draw distance and long
enough that a Tank is visible before it reaches you.

### `Combat/ProjectileService.lua` → `"ProjectileService"` — **built**
```lua
ProjectileService:throw(player: Player, itemId: string?, origin: Vector3?, direction: Vector3?, power: number?)
```
Handles `Remotes.Event.ThrowItem`. Pipe bomb (attracts the horde, then explodes via
`DamageService:applyExplosion`), molotov (a fire pool that ignites infected through
`InfectedService:ignite`), hazardous waste (a lure zone that holds a wave in one
place for fifty seconds).

**Everything but the id is optional, and that is what decides where a bomb goes.**
`ThrowItem` supplies a camera ray, so a throw aimed up onto a balcony arrives
there. `InventoryService`'s UseItem path supplies neither, and the server then
falls back to its own view of the character — a level `LookVector`. Both are
legitimate entry points; only one of them aims. Anything new that throws should
send a ray unless it genuinely means "straight ahead".

The thing that flies is a procedural part built unconditionally; the map's model
is **dressing**, applied when there is one. A missing model is not a failure and
is not warned about — it means a grey cylinder, not a throw that does not happen.

## New client modules

| Path | Registry name | Owns |
|---|---|---|
| `UI/MainMenuController.lua` | `"MainMenuController"` | mode select, server browser, lobby countdown |
| `UI/WaveController.lua` | `"WaveController"` | wave timer, wave pips, wave announcements |
| `UI/InfectedController.lua` | `"InfectedController"` | Versus special-infected class picker |
| `UI/MapVoteController.lua` | `"MapVoteController"` | end-of-round and fresh-server map vote |
| `UI/ScaleLayer.lua` | *(none — a helper, not a controller)* | resolution independence for every ScreenGui |
| `UI/GamepadFocus.lua` | *(none — a helper)* | GuiService.SelectedObject, so a controller can reach a screen |
| `UI/ImageCheck.lua` | *(none — a helper)* | fetches every image id once and warns by name when one will not draw |
| `UI/TouchController.lua` | `"TouchController"` | the on-screen pad, only under the touch scheme |
| `UI/SettingsController.lua` | `"SettingsController"` | every player preference, and the panel that edits them |

### What a survivor is carrying, on the survivor

`Survivors/CarryVisualService.lua` mirrors two slots onto the character model,
server-side, so every client sees the same thing at the same moment:

| Mount | Shows | Anchor |
|---|---|---|
| `Back` | the Health slot, unless it is the selected slot | `UpperTorso` / `Torso` |
| `Hands` | the selected weapon, or a selected medkit | `RightHand` / `Right Arm` |

A weapon is held by lining its `Grip` attachment up with the hand rather than by
a table of per-weapon offsets. `PlaceholderFactory` stamps that attachment on
every world model and every viewmodel — at the model origin for a shape it
authored, guessed from the handle's own box for one it was given — so nothing
downstream has to know what a particular gun looks like.

This is not only decoration. `ImpactController` resolves another player's muzzle
flash by searching their character for an attachment named `Muzzle`, falling back
to a guessed point in front of their face. Every world weapon model carries one,
so a gun in somebody's hands moves their muzzle flash to its barrel with no
change on the client at all.

`ViewmodelController` hides the LOCAL player's own copy, keyed to whether the
camera is third-person rather than to whether the viewmodel is up — a downed
survivor's viewmodel goes away while their camera stays at their head.

### The flashlight

`AtmosphereService` opens the round under a low orange sun and is pitch dark by
wave 7. Until this existed that ramp was pointed at nothing — the map went black
and the survivors had no way to see into it.

Two lights per survivor, and they are not the same light:

- **The world beam** hangs off the weapon in their hands (`CarryVisualService`),
  so a teammate's beam sweeping a doorway is a real read from forty studs. Only
  weapons carry one: a survivor who has pulled their medkit out goes dark for the
  length of the heal.
- **The view beam** is the local player's own, carried by the camera
  (`Client/Effects/FlashlightController`), because a gun points where the ARM
  points and a player aims with the CAMERA. `ViewmodelController` switches off
  the owner's world beam for them alone, so nobody sees two coincident lights.

It is always on, with no toggle — a toggle needs a key, and only a keyboard has
one to spare. `GameConfig.Flashlight` carries the reasoning and the numbers, both
shared by the two lights so they cannot drift apart.

The `brightness` setting is the other half of playing in the dark: a client-side
`ColorCorrectionEffect` owned by `OverlayController`, lifting mid-tones without
opening the fog, so a phone in daylight is not a different game.

Shadows are off on both: four shadow-casting spotlights in a horde is the most
expensive thing this game could ask a phone to draw, and against fog that thick
the shadows are invisible.

### Animations

`Shared/Util/AnimationCache.lua` owns one `Animation` instance per asset id, for
the life of the server, and preloads them. Nothing else may build one.

Two things make an animation fail intermittently, and both were happening:

1. **Destroying the `Animation` after `LoadAnimation`.** The track resolves its
   asset fetch *through* that instance, so destroying it leaves the track
   pointing at nothing — which works when the id was already cached and silently
   never plays when it was not.
2. **Not preloading.** A track whose asset has not arrived reports `IsPlaying`,
   has `Length == 0`, and moves nothing. Forty zombies spawn in the first ten
   seconds of a round.

A third made it hard to diagnose: `LoadAnimation` does **not** throw for an id
that is missing, private, or owned by another account — it returns an ordinary
track that never plays. `PreloadAsync`'s per-asset status is what actually knows,
so `AnimationCache.hasFailed(id)` is how a broken id gets named in the log.

Roblox only plays animations owned by the place's creator or by Roblox itself.
An id uploaded under a personal account, in a group-owned game, fails exactly
this way — and that is now the message you get.

Audit check **9j** rejects both `Instance.new("Animation")` outside the cache and
any destroy-after-load.

### Dollars, the shop, and loadouts

The only persistent state in the game. Everything else is round-scoped and dies
with the server.

| File | Owns |
|---|---|
| `Shared/Config/EconomyConfig.lua` | earning AND pricing, in one table |
| `Shared/Config/LoadoutConfig.lua` | what a loadout is; `sanitise` is the only way one enters the game |
| `Server/Economy/ProfileService.lua` | the DataStore, the session lock, the in-memory profile |
| `Server/Economy/EconomyService.lua` | the earning rules and the purchase path |
| `Server/Survivors/LoadoutService.lua` | which two weapons you spawn holding |
| `Client/UI/ProfileController.lua` | this client's mirror; the shop and loadout screens both read it |

**Earning and pricing live together** because they are two ends of one number.
`scripts/economy.py` models a round from the real wave table and the real
catalogue and fails when the roster stops taking 30–40 rounds to unlock; it runs
in `check.sh`. The one thing it cannot derive is how many infected a player kills
— the Director replaces what you shoot — so that is a stated assumption printed
in every report.

**The one rule in `ProfileService`: a profile that failed to LOAD is never
SAVED.** If the store is unreachable the player gets a working default for the
session, marked `degraded`, and nothing is written — the alternative is a
transient outage replacing forty rounds of progress with a starting balance.
Session locking (`lock = {jobId, at}`, taken inside an `UpdateAsync`, stolen only
once stale) exists because Roblox will run one player in two servers at once.
Every operation on the key is an `UpdateAsync`; a Get-then-Set cannot notice a
lock changing between the two.

**The client never names a price.** A purchase carries an item id; cost,
availability and affordability are all answered server-side.

**Balance is an attribute**, not a remote — it moves on every kill. The `+$4`
popup is derived from the delta, so no remote carries it and the round bonus gets
the same treatment for free.

**A loadout is Primary + Secondary only.** Medkits, pills and throwables stay on
the floor of the map: the scavenging loop is most of what makes a level worth
walking slowly through, and a loadout that could carry a kit turns Dollars into a
purchase of survivability rather than of preference.

### The menu at phone height

`MainMenuController.layoutColumns` measures the title, the mode entries and the
bottom nav row against the real reference height and lays them out so they cannot
overlap. Below `COMPACT_HEIGHT` the poster becomes a phone menu: smaller title,
shorter entries with their pitch lines hidden, and the control briefing dropped.

This exists because at the 0.75 scale floor a phone in landscape reports about
500 reference pixels rather than 900, and the layout had been overlapping itself
there — invisibly on every desktop and tablet, which is the shape of bug that
ships. `verify_menu.py` ports the function to Python and checks nine viewports.

### Settings

`Shared/Config/SettingsConfig.lua` declares WHAT the options are — key, kind,
range, default, category. `UI/SettingsController.lua` owns the store, draws the
panel and decides what applying one means. Adding an option is a change to the
config only.

One panel, opened from the main menu's `SETTINGS` line, from `O` or the
gamepad's view button in a live round, and from a button in the top-right corner
on a phone. Preferences persist through `TeleportService`'s teleport settings, so
they survive the matchmaker moving a player between servers.

**Personal difficulty** is the one setting with a server side. The client sends
`SetDifficulty`; the server coerces it through the same `SettingsConfig` table
and writes `Attributes.Player.Difficulty`, and `DamageService` multiplies damage
arriving AT that player by `SettingsConfig.Difficulty[choice].incomingDamage`.
Every multiplier in that table is at most 1, so the setting can cost a player
difficulty and can never buy them an advantage.

### Where a shot comes from

Two origins, and they are not the same:

- **The ray** starts at `CameraController:getAimCFrame()`. You shoot where you
  look, and the aim carries only its share of the recoil and none of the shake.
- **The tracer** starts at `ViewmodelController:getMuzzlePosition()`. In first
  person the gun sits below and right of the eye, so a tracer drawn from the
  camera visibly leaves the player's face.

Same hit point either way — only the line between differs, and the line is the
only part anybody sees. The camera origin is still what goes over the wire and
what `rememberEcho` records, so the server's copy of a shot you already drew is
still recognised as yours.

### Input schemes

`InputController:getScheme()` returns `"Desktop"`, `"Touch"` or `"Gamepad"` —
which input the player is **using**, not what the device has, because a laptop
with a touchscreen and a pad plugged in is all three. It follows the last
deliberate press and fires `schemeChanged`. Anything that draws a key glyph,
sizes a tap target, or decides whether to put buttons on screen reads it.

Two rules follow from it:

- **A screen a player must act on captures gamepad focus when it opens and
  releases it when it closes** (`GamepadFocus`). Without that, a controller has
  no cursor and the screen is dead — every button present, none reachable. A
  release that never happens is worse: selection stuck on a hidden button eats
  every D-pad press in the game afterwards.
- **On-screen buttons call `InputController:raise(action, down)`**, never a
  remote directly. That keeps one definition of what a verb costs — the disabled
  check, the held-state bookkeeping and the forward are the same code for a
  finger as for a trigger.

### Screen layout contract

Two rules, and everything on screen follows both.

**1. Lay out in reference pixels, never in hardware pixels.** Offsets are chosen
against a 900px-tall viewport. Every ScreenGui that draws in offsets puts its
content inside `ScaleLayer.new(gui)` and parents to the returned Frame, never to
the ScreenGui. `UITheme.Scale` / `UITheme.scaleFor` own the factor, so two layers
built by two controllers always agree — which is what lets `WaveController` hand
`HudController` a pixel inset and have it land correctly on a phone.

The one boundary that has to convert: anything reading a real screen coordinate
(`WorldToViewportPoint`, a mouse position) must divide by `ScaleLayer.getFactor()`
before using it as an offset inside a layer. `AbsolutePosition`/`AbsoluteSize`
need no conversion — both already account for the scale.

Full-bleed washes with no offsets in them (the vignette, the teleport fade) stay
outside a layer. There is nothing there for a scale to correct.

**2. `UITheme.DisplayOrder` owns the stack.** No controller invents its own
number. Ties are resolved by ScreenGui creation order, which is boot order, which
is not a decision anyone made — so anything that must cover something else gets
its own entry. The map vote sits **above** the menu because the vote runs at the
same time as the end-of-round scoreboard, not after it.

## Asset loading

`Assets/PlaceholderFactory` keeps its name and API but changes behaviour: it now
**prefers the user's real models** and falls back to procedural grey-box only when
one is absent.

```
ReplicatedStorage/Assets/
    Infected/<Kind>/     one or more rig variants — pick one at RANDOM per spawn
    Weapons/<modelName>  third-person / world model
    Viewmodels/<modelName>
```

- `<Kind>` matches `Enums.Infected` exactly. `Common/` holds ~13 variants and the
  random pick is what makes a horde read as a crowd instead of a clone army.
- Weapon models are found by `WeaponConfig` **`modelName`**, not by the enum key —
  `"(71 Mag) PPSh-41"` is not a valid Luau identifier.
- The supplied rigs are a mix: **Commons, Hunter, Jockey and Tank are R6; Rusher is
  R15.** `RigUtil` and `GoreConfig.Dismemberment.Severable` already cover both.
  Never look a Humanoid up by name — the Rusher's is named `Zombie`.
- Hunter has both `Head` and `FakeHead`; treat a hit on either as a headshot.
