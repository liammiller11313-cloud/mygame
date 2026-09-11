--!strict
--[[
	BallisticsService — where a trigger pull becomes a hit.

	The client fires the instant you click: muzzle flash, tracer, recoil, ammo
	count, all predicted locally so the gun feels connected to the mouse. None of
	that is a hit. This service decides what was actually struck, and it assumes
	every field in the packet is a lie until it survives GameConfig.HitValidation.

	── THE SHARED CONE ─────────────────────────────────────────────────────────
	Read Shared/Util/ShotPattern.lua's header first. The client sends ONE integer
	seed; both machines feed it to Random.new() and get the identical pellet
	spread, which is the only reason ten shotgun tracers land where the ten
	pellets resolved. That contract has two halves and this file owns the second:

	  * the seed comes from the client (and is rejected unless it is an integer
	    inside ShotPattern.generateSeed's range — a client can pick WHICH
	    deterministic pattern it gets, never WHERE the pellets go)
	  * the spread does NOT come from the client. It is recomputed here, from the
	    weapon definition and the shooter's own accumulated bloom:

	        base   = isAiming and spreadAim or spreadHip
	        base  += spreadMoving          while the shooter is actually moving
	        cone   = min(base + bloom, spreadMax)
	        bloom += bloomPerShot          after the shot, capped at spreadMax
	        bloom -= bloomRecovery * dt    continuously since the last shot

	    WeaponController must mirror that formula exactly. If the two sides
	    disagree on the cone angle, the same seed produces different directions
	    and the deterministic-pattern guarantee is worth nothing. The resolved
	    cone is echoed back in the WeaponFired payload so remote clients can
	    reproduce it without guessing.

	── PERFORMANCE ─────────────────────────────────────────────────────────────
	A four-survivor firefight is up to 88 accepted shots a second, and a shotgun
	shot is ten pierce casts. Nothing in the hot loop allocates that it does not
	have to: the pierce predicate is a module-level function with no upvalues, the
	rate limiter is a fixed circular buffer, and effect replication is capped per
	shot and range-culled rather than broadcast.

	Melee weapons are not handled here at all — MeleeService owns fireMode
	"Melee", and a swing that arrived on this remote is dropped.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local AudioConfig = require(Shared.Config.AudioConfig)
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local GoreConfig = require(Shared.Config.GoreConfig)
local RaycastUtil = require(Shared.Util.RaycastUtil)
local Registry = require(Shared.Util.Registry)
local Signal = require(Shared.Util.Signal)
local Remotes = require(Shared.Net.Remotes)
local RigUtil = require(Shared.Util.RigUtil)
local ShotPattern = require(Shared.Util.ShotPattern)
local Trove = require(Shared.Util.Trove)
local Types = require(Shared.Types)
local WeaponConfig = require(Shared.Config.WeaponConfig)

type WeaponDefinition = WeaponConfig.WeaponDefinition

--[[ Everything the server tracks about one shooter. Bloom lives here rather than
     on the character so switching weapons or dying does not hand the player a
     free reset of a cone they blew out a quarter of a second ago. ]]
type ShooterState = {
	rateTimes: { number }, -- circular buffer of the last N accepted shot times
	rateCursor: number,
	lastFireAt: number,
	bloom: number, -- degrees of cone added by recent shots
	bloomAt: number, -- when bloom was last brought up to date
	bloomWeaponId: string?,
	isAiming: boolean,
}

local BallisticsService = {}

--[[ (shooter: Player, weaponId: string, definition) — a shot the server accepted
     and resolved. Distinct from the WeaponFired remote beside it, which tells
     OTHER clients to draw a muzzle flash: this is for the server's own listeners,
     and CarryVisualService uses it to play the third-person shot animation on
     the character everyone is looking at. ]]
BallisticsService.fired = Signal.new()

local VALIDATION = GameConfig.HitValidation

-- One slot per shot allowed in the window, so the check is a single compare
-- against the oldest of the last N shots. No table churn, no sorting, no drift.
local RATE_SLOTS = math.max(math.floor(VALIDATION.MaxShotsPerSecond), 1)
local RATE_WINDOW = 1.0

--[[
	The global rate cap lets an auto shotgun through at seven times its real fire
	rate, so the weapon's own rpm is enforced too. The leniency exists because a
	client firing at exactly 60/rpm will sometimes have two packets arrive
	bunched by jitter, and silently eating a legitimate shot is a far worse bug
	than letting a cheater gain 15%.
]]
local FIRE_DELAY_LENIENCY = 0.85

-- Mirrors ShotPattern.generateSeed's range. A seed outside it is not a client
-- this build produced.
local SEED_MIN = 1
local SEED_MAX = 2147483646

-- Held-trigger intent, from the humanoid rather than from velocity, plus a
-- velocity fallback for being carried, shoved or falling. A shooter drifting at
-- walking-pace-over-ten is not "moving" for accuracy purposes.
local MOVE_INTENT_EPSILON = 0.1
local MOVING_SPEED_SQUARED = 9 -- (3 studs/s)^2

--[[
	Ten tracers from one shotgun blast read as one cone of light and cost ten
	remote events to draw it. Three is enough to sell the spread; index 1 is
	ShotPattern's guaranteed centre pellet, so the shot always draws where the
	crosshair was. Impacts are capped for the same reason — a wall full of pellet
	marks is worth something, ten remote events per trigger pull is not.
]]
local MAX_TRACER_EVENTS_PER_SHOT = 3
local MAX_IMPACT_EVENTS_PER_SHOT = 4

-- Effects beyond this are never sent. Same distance gore uses, for the same
-- reason: a firefight across the map must not cost a distant client anything.
local EFFECT_RADIUS = GoreConfig.Budget.CullDistance

local EPSILON = 1e-4

--[[ States in which a survivor cannot fire at all. Incapacitated is deliberately
     absent: being down means the pistol only, which is checked separately. ]]
local CANNOT_FIRE_STATES: { [string]: boolean } = {
	[Enums.SurvivorState.Dead] = true,
	[Enums.SurvivorState.Spectating] = true,
	[Enums.SurvivorState.LedgeHanging] = true,
	-- Pinned survivors cannot shoot their way out. That is the whole point of a
	-- pin: it costs the team a second player's attention to answer.
	[Enums.SurvivorState.Pinned] = true,
}

--[[ Roblox material -> AudioConfig.Impact key. Purely a naming bridge; the mix
     numbers all live in AudioConfig. ]]
local MATERIAL_SOUND: { [Enum.Material]: string } = {
	[Enum.Material.Concrete] = "Concrete",
	[Enum.Material.Brick] = "Concrete",
	[Enum.Material.Cobblestone] = "Concrete",
	[Enum.Material.Rock] = "Concrete",
	[Enum.Material.Slate] = "Concrete",
	[Enum.Material.Pavement] = "Concrete",
	[Enum.Material.Limestone] = "Concrete",
	[Enum.Material.Metal] = "Metal",
	[Enum.Material.DiamondPlate] = "Metal",
	[Enum.Material.CorrodedMetal] = "Metal",
	[Enum.Material.Foil] = "Metal",
	[Enum.Material.Wood] = "Wood",
	[Enum.Material.WoodPlanks] = "Wood",
	[Enum.Material.Glass] = "Glass",
	[Enum.Material.Ice] = "Glass",
	[Enum.Material.Water] = "Water",
	[Enum.Material.Grass] = "Dirt",
	[Enum.Material.LeafyGrass] = "Dirt",
	[Enum.Material.Ground] = "Dirt",
	[Enum.Material.Mud] = "Dirt",
	[Enum.Material.Sand] = "Dirt",
	[Enum.Material.Snow] = "Dirt",
}
local DEFAULT_MATERIAL_SOUND = "Concrete"

local shooters: { [Player]: ShooterState } = {}
local trove = Trove.new()
local warned: { [string]: boolean } = {}

local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("[BallisticsService] " .. message)
end

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isFiniteVector(value: any): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	local vector = value :: Vector3
	return isFiniteNumber(vector.X) and isFiniteNumber(vector.Y) and isFiniteNumber(vector.Z)
end

local function isValidSeed(seed: any): boolean
	return isFiniteNumber(seed) and seed >= SEED_MIN and seed <= SEED_MAX and math.floor(seed) == seed
end

local function stateFor(player: Player): ShooterState
	local state = shooters[player]
	if not state then
		state = {
			rateTimes = table.create(RATE_SLOTS, 0),
			rateCursor = 0,
			lastFireAt = 0,
			bloom = 0,
			bloomAt = 0,
			bloomWeaponId = nil,
			isAiming = false,
		}
		shooters[player] = state
	end
	return state :: ShooterState
end

--[[
	True when this shot fits under MaxShotsPerSecond. The slot about to be
	overwritten holds the Nth-most-recent shot; if that was under a second ago,
	N shots already landed inside the window and this one is dropped. Silently —
	an over-rate client is either lagging or cheating, and erroring at it tells a
	cheater exactly which check they tripped.
]]
local function admitRate(state: ShooterState, now: number): boolean
	local slot = (state.rateCursor % RATE_SLOTS) + 1
	if now - state.rateTimes[slot] < RATE_WINDOW then
		return false
	end
	state.rateTimes[slot] = now
	state.rateCursor = slot
	return true
end

--[[ Brings bloom up to the present. Switching weapons clears it: the cone
     belongs to the gun that blew it out, not to the player. ]]
local function decayBloom(state: ShooterState, definition: WeaponDefinition, now: number)
	if state.bloomWeaponId ~= definition.id then
		state.bloomWeaponId = definition.id
		state.bloom = 0
	else
		local elapsed = math.max(now - state.bloomAt, 0)
		state.bloom = math.max(state.bloom - definition.bloomRecovery * elapsed, 0)
	end
	state.bloomAt = now
end

local function isMoving(character: Model, humanoid: Humanoid): boolean
	if humanoid.MoveDirection.Magnitude > MOVE_INTENT_EPSILON then
		return true
	end
	local root = RigUtil.getRoot(character)
	if not root then
		return false
	end
	local velocity = root.AssemblyLinearVelocity
	return velocity.X * velocity.X + velocity.Z * velocity.Z > MOVING_SPEED_SQUARED
end

--[[ The cone, in degrees of half-angle. Pure read — call decayBloom first.

     The crouch multiplier is applied LAST, to the clamped total, so it tightens
     the movement penalty and the recoil bloom as well as the base — which is the
     whole reason to crouch behind an automatic. Read from the attribute rather
     than from anything the client sent: the server owns crouch, and WeaponController
     reads the same attribute so the crosshair cannot promise a cone this will not
     fire. ]]
local function coneFor(
	shooter: Player,
	state: ShooterState,
	definition: WeaponDefinition,
	character: Model,
	humanoid: Humanoid
): number
	local base = if state.isAiming then definition.spreadAim else definition.spreadHip
	if isMoving(character, humanoid) then
		base += definition.spreadMoving
	end
	-- max() guards a definition whose spreadMax is under its own base spread:
	-- bloom may only ever widen the cone, never tighten it.
	local cone = math.min(base + state.bloom, math.max(definition.spreadMax, base))
	if Attributes.get(shooter, Attributes.Player.IsCrouching, false) then
		cone *= GameConfig.Survivor.CrouchSpreadMultiplier
	end
	return cone
end

--[[
	What one round does when it meets a surface. No upvalues, so this is created
	once for the whole server rather than per shot.

	  true   the round passes through and spends one point of penetration
	  false  the round stops here

	Corpses, gibs and severed limbs return true unconditionally. RigUtil.makeDebris
	already sets CanQuery = false on them so they should never appear at all; this
	covers the frame between a humanoid reaching zero and GoreService taking the
	body, during which a fresh corpse must not eat the bullet meant for the Common
	standing behind it.
]]
local function isPierceable(result: RaycastResult): boolean
	local instance = result.Instance
	local group = instance.CollisionGroup
	if group == "Debris" or group == "Gib" then
		return true
	end

	local model, humanoid = RigUtil.getCharacterFromPart(instance)
	if not model or not humanoid then
		-- Scenery. Walls stop rounds; that is what makes cover mean anything.
		return false
	end
	if model:GetAttribute(Attributes.Infected.IsDead) == true or humanoid.Health <= 0 then
		return true
	end
	if Players:GetPlayerFromCharacter(model) then
		--[[
			A round stops in a teammate ONLY IF IT COULD HAVE HURT THEM.

			With friendly fire on, letting a rifle thread the whole team is how a
			tense mistake becomes a wipe, and that is what this rule was for.
			With it off — which is the shipped setting — DamageService returns a
			blocked result for that teammate, so the round did nothing to anybody
			and stopping it bought nothing. What it cost was the doorway: every
			rifle round and every shotgun pellet terminating in a friend's back,
			no damage to them, none to the horde behind them, no hitmarker, no
			blood and no impact effect. Just a tracer stopping short and the
			shooter being told off for it every four seconds.

			MeleeService reasons from the same premise and reaches the same
			answer out loud — "a machete that a teammate can body-block is a
			machete nobody swings in the doorway it exists for" — and adds every
			survivor to its ignore list. Guns and melee now agree about the same
			rule under the same flag instead of contradicting each other.

			No penetration is spent either way, exactly as a corpse costs none: a
			body that cannot be hurt should not be able to weaken the shot that
			passes through it.
		]]
		return not GameConfig.Survivor.FriendlyFireEnabled
	end
	return true
end

local function headPositionOf(character: Model): Vector3?
	local head = character:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head.Position
	end
	local root = RigUtil.getRoot(character)
	return if root then root.Position else nil
end

function BallisticsService:init()
	trove:add(Players.PlayerRemoving:Connect(function(player: Player)
		shooters[player] = nil
	end))
end

function BallisticsService:start()
	trove:add(Remotes.Event.FireWeapon.OnServerEvent:Connect(function(player: Player, payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		-- clientTime rides along in the payload and is deliberately ignored:
		-- nothing in this build records a position history to rewind against, so
		-- honouring HitValidation.MaxRewindTime would be theatre. See the report.
		BallisticsService:resolveShot(player, payload.origin, payload.direction, payload.seed)
	end))

	--[[
		Aim state is tracked here because the cone depends on it and the cone is
		this service's to compute. Other services are free to connect to the same
		remote; Roblox delivers to every listener.
	]]
	trove:add(Remotes.Event.SetAimState.OnServerEvent:Connect(function(player: Player, isAiming: any)
		if typeof(isAiming) ~= "boolean" then
			return
		end
		stateFor(player).isAiming = isAiming
	end))
end

--[[ True while the player is aiming down sights, as the server understands it. ]]
function BallisticsService:isAiming(player: Player): boolean
	local state = shooters[player]
	return state ~= nil and state.isAiming
end

--[[ The cone the player's next shot would use, in degrees. For the crosshair's
     server-side twin, debug overlays and tests — resolveShot does not use it. ]]
function BallisticsService:getEffectiveSpread(player: Player): number
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not humanoid then
		return 0
	end

	local inventory = Registry.find("InventoryService")
	if not inventory then
		return 0
	end
	local _, definition = inventory:getActiveWeapon(player)
	if not definition then
		return 0
	end

	local state = stateFor(player)
	decayBloom(state, definition, os.clock())
	return coneFor(player, state, definition, character, humanoid)
end

--[[
	Resolves one trigger pull. Returns the hits, newest cast last, so a caller
	can read the shot without listening for anything.

	Every rejection returns an empty array and says nothing to the client. The
	client already drew its own tracer; it reconciles from the ammo attributes and
	the absence of a hitmarker, which is quieter and far harder to probe than an
	error would be.
]]
function BallisticsService:resolveShot(
	shooter: Player,
	origin: Vector3,
	direction: Vector3,
	seed: number
): { Types.HitRecord }
	local records: { Types.HitRecord } = {}

	-- ── shape of the packet ──────────────────────────────────────────────────
	if typeof(shooter) ~= "Instance" or not shooter:IsA("Player") then
		return records
	end
	if not isFiniteVector(origin) or not isFiniteVector(direction) then
		return records
	end
	if direction.Magnitude < EPSILON then
		return records
	end
	if not isValidSeed(seed) then
		return records
	end

	-- ── is this player in a position to shoot at all ─────────────────────────
	local character = shooter.Character
	if not character or not character.Parent then
		return records
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return records
	end

	local now = os.clock()
	local state = stateFor(shooter)
	if not admitRate(state, now) then
		return records
	end

	local inventory = Registry.find("InventoryService")
	if not inventory then
		warnOnce("inventory", "InventoryService is not registered; every shot is being dropped")
		return records
	end

	local weaponId, definition = inventory:getActiveWeapon(shooter)
	if typeof(weaponId) ~= "string" or typeof(definition) ~= "table" then
		return records
	end
	if definition.fireMode == "Melee" then
		-- MeleeService owns the swing. A machete arriving on FireWeapon is a
		-- confused client, not an attack.
		return records
	end

	local survivors = Registry.find("SurvivorService")
	if survivors then
		if CANNOT_FIRE_STATES[survivors:getState(shooter)] then
			return records
		end
		-- Down means the pistol, and only the pistol. Firing a rifle from the
		-- floor would remove the entire cost of going down.
		if survivors:isIncapacitated(shooter) and weaponId ~= GameConfig.Survivor.IncapWeapon then
			return records
		end
	end

	if now - state.lastFireAt < WeaponConfig.getFireDelay(definition) * FIRE_DELAY_LENIENCY then
		return records
	end

	-- ── is the shot coming from where the shooter says it is ─────────────────
	local headPosition = headPositionOf(character)
	if not headPosition then
		return records
	end
	if (origin - headPosition).Magnitude > VALIDATION.PositionTolerance then
		return records
	end
	if
		VALIDATION.RequireLineOfSight
		and not RaycastUtil.hasLineOfSight(headPosition, origin, { character })
	then
		-- Within tolerance but through a wall: the muzzle has been pushed into
		-- the room next door.
		return records
	end

	-- Ammo is InventoryService's, always. It is also the last check, so a shot
	-- rejected for any other reason costs the player nothing.
	if not inventory:consumeAmmo(shooter, 1) then
		return records
	end

	-- ── the cone ─────────────────────────────────────────────────────────────
	local unit = direction.Unit
	decayBloom(state, definition, now)
	local spread = coneFor(shooter, state, definition, character, humanoid)
	state.bloom = math.min(state.bloom + definition.bloomPerShot, math.max(definition.spreadMax, 0))
	state.lastFireAt = now

	--[[
		Told to everyone else before a single ray is cast. Remote muzzle flash and
		gunfire are how a player knows a teammate is engaging something, and the
		couple of milliseconds the resolution takes is time that feedback does not
		need to spend waiting. `spread` rides along so a remote client can rebuild
		the identical cone from the seed.
	]]
	Remotes.fireAllExcept("WeaponFired", shooter, {
		shooter = shooter,
		weaponId = weaponId,
		origin = origin,
		direction = unit,
		seed = seed,
		spread = spread,
	})

	--[[ Everyone but the shooter, for the same reason the WeaponFired remote
	     above them excludes the shooter: they have already had it. The client
	     plays its own gunshot flat and immediate on the frame the trigger goes
	     down, so a world emitter at the muzzle reached them a round trip later
	     as a slapback echo of their own gun — on every shot, all game.

	     The cost is bounded and was designed for exactly this call. _playExcluding
	     gathers listeners inside the definition's own rolloff and nobody else, so
	     a four-player team spread across a map is usually one or two emitters
	     rather than three; it admits ONCE against the category budget however
	     many it builds; and it picks the id and the pitch once, so the team hears
	     one gunshot from one gun rather than a chord. ]]
	local audio = Registry.find("AudioService")
	if audio then
		audio:playAt(AudioConfig.WeaponFire[weaponId], origin, nil, shooter)
	end

	--[[ After the remote and the sound, before the rays. Everything a listener
	     does with this is presentation on somebody else's screen, and none of it
	     should sit in front of the resolution the shot is actually for. ]]
	BallisticsService.fired:fire(shooter, weaponId, definition)

	-- ── resolution ───────────────────────────────────────────────────────────

	--[[
		A round that FLIES resolves nothing here.

		Everything above this line still happened — the shooter was validated, the
		ammunition was spent, the other clients were told and the report played —
		because all of that is about pulling the trigger and none of it is about
		where the shot lands. What is skipped is the part that assumes the shot has
		ALREADY landed: the pellet rays, the tracer, the impact, and the blast at
		the end of the ray.

		A travelling round decides all four for itself, later, wherever it gets to.
		Casting a ray as well would blow a hole in whatever is in front of the
		shooter at the instant they fired AND send a rocket at it — the weapon
		would hit twice, once instantly.

		Returns no records on purpose. There is no hit yet to report, and inventing
		one would put a hitmarker on a shot still in the air.
	]]
	--[[
		And the paint, for the one gun that has any.

		Taken from the SEED rather than rolled here, which is what makes one
		trigger pull one colour everywhere: the shooter's own tracer is drawn on
		their machine from the same seed before this code has run at all, and a
		colour rolled on the server would have meant a green streak followed by a
		pink splat. See WeaponConfig.paintColor.

		Nil for all thirty-five other guns, and the pellet loop tests it before it
		tests anything else, so paint costs a nil check on every other shot in
		the game. See PaintService.

		ABOVE the travelling-round branch, not below it, because the paintball is
		now on both sides of that line: its colour has to reach the round it
		launches as well as the splat a hitscan shot leaves. It was below, which
		meant the one gun this exists for could not see it.
	]]
	local paintColor = WeaponConfig.paintColor(definition, seed)
	local paint: any = if paintColor then Registry.find("PaintService") else nil

	if definition.projectile then
		local projectiles = Registry.find("ProjectileService")
		if projectiles and typeof(projectiles.launch) == "function" then
			--[[
				A round that goes off, or a round that lands.

				The condition used to require a blast, which quietly meant a
				travelling round could only ever be a rocket: give the classic
				paintball a ProjectileProfile and no blastRadius and it fell
				straight through to the hitscan path below, resolving at the
				trigger while carrying a description of a ball in flight.

				`contact` is what the other half needs — the single-target damage,
				the paint profile and this shot's colour. Nil for a launcher, which
				re-finds its targets in a radius and paints nothing.
			]]
			local contact: any = nil
			if not (definition.blastRadius and definition.blastDamage) then
				contact = {
					damage = definition.damage,
					paint = definition.paint,
					tint = paintColor,
				}
			end
			projectiles:launch(
				shooter,
				weaponId,
				origin,
				unit,
				definition.projectile,
				definition.blastRadius or 0,
				definition.blastDamage or 0,
				character,
				contact
			)
		else
			--[[ Loud, because the alternative is silent. A hitscan weapon with no
			     ProjectileService still fires and simply does not explode; this one
			     fires NOTHING, and a player whose launcher does nothing at all has
			     no way to tell that from a bug in their own aim. ]]
			warnOnce(
				"projectile",
				"ProjectileService:launch is missing; travelling-round weapons fire nothing at all"
			)
		end
		return records
	end

	local damageService = Registry.get("DamageService")
	local damageType = if definition.pellets > 1 then Enums.DamageType.Pellet else Enums.DamageType.Bullet
	local maxDistance = definition.maxRange * VALIDATION.MaxRangeSlack
	local directions = ShotPattern.generate(unit, seed, definition.pellets, spread)
	local ignore: { Instance } = { character }

	local tracersSent = 0
	local impactsSent = 0

	--[[ Where the shot landed, for the pogo below. Taken from the first pellet
	     only: a volley is one trigger pull and must be one launch. ]]
	local pogoAt: Vector3? = nil
	local pogoHit = false

	for _, pelletDirection in directions do
		local hits = RaycastUtil.pierce(
			origin,
			pelletDirection,
			maxDistance,
			definition.penetration,
			ignore,
			isPierceable
		)

		local last = hits[#hits]
		local endPosition = if last then last.position else origin + pelletDirection * maxDistance
		local piercedBodies = 0

		if pogoAt == nil then
			pogoAt = endPosition
			--[[ Whether anything was actually struck, kept apart from where the
			     ray ended. They differ on a miss, where endPosition is simply the
			     far end of the ray — and a pogo off thin air is the exact bug the
			     standalone pack shipped. See PogoService. ]]
			pogoHit = last ~= nil
		end

		for _, hit in hits do
			local model, targetHumanoid = RigUtil.getCharacterFromPart(hit.instance)

			if model and targetHumanoid and RigUtil.isAlive(model) then
				local region = RigUtil.getHitRegion(hit.instance)
				local result = damageService:applyDamage(
					model,
					definition.damage,
					Types.newDamageContext({
						attacker = shooter,
						weaponId = weaponId,
						damageType = damageType,
						region = region,
						hitPart = hit.instance,
						hitPosition = hit.position,
						hitNormal = hit.normal,
						direction = pelletDirection,
						distance = hit.distance,
						piercedCount = piercedBodies,
					})
				)

				if not result.blocked then
					table.insert(records, {
						model = model,
						part = hit.instance,
						position = hit.position,
						normal = hit.normal,
						distance = hit.distance,
						region = region,
						result = result,
					})
				end

				piercedBodies += 1
			elseif not model then
				-- Scenery. Blood on flesh is GoreService's; sparks and dust on the
				-- world are this one's.

				--[[ And paint, for the gun that leaves some. Applied before the
				     impact event so the answer can ride along on it: PaintService
				     returns the colour it actually put down, or nil when the shot
				     landed on something it refuses to recolour — a puzzle prop, a
				     barricade, a wall too big to be a prop — and the client then
				     draws a splat only where a real one went. A splat on a
				     surface that did not change colour is the gun looking broken
				     in exactly the places it is being careful. ]]
				local splat: Color3? = nil
				if paintColor and paint and typeof(paint.splash) == "function" then
					splat = paint:splash(hit.instance, paintColor, definition.paint)
				end

				if impactsSent < MAX_IMPACT_EVENTS_PER_SHOT then
					impactsSent += 1
					Remotes.fireInRange("ImpactEffect", hit.position, EFFECT_RADIUS, {
						position = hit.position,
						normal = hit.normal,
						material = hit.material,
						damageType = damageType,
						paint = splat,
					})
				end
				if audio then
					audio:playAt(
						AudioConfig.Impact[MATERIAL_SOUND[hit.material] or DEFAULT_MATERIAL_SOUND],
						hit.position
					)
				end
			end
		end

		if tracersSent < MAX_TRACER_EVENTS_PER_SHOT then
			tracersSent += 1
			-- Ranged from the middle of the beam: a tracer that crosses a room is
			-- worth drawing to a client standing at either end of it.
			Remotes.fireInRange("TracerEffect", (origin + endPosition) * 0.5, EFFECT_RADIUS, {
				origin = origin,
				endPosition = endPosition,
				weaponId = weaponId,
				--[[ Nil for every gun but the paintball. The shooter never sees
				     this one — their own tracer was drawn locally from the same
				     seed, and is already this colour — so it is here for the rest
				     of the team, who would otherwise watch a green streak land as
				     a pink splat. ]]
				tint = paintColor,
			})
		end

		--[[
			A blast weapon detonates where its shot lands.

			After the pellet's own damage, not instead of it: a rocket that hits a
			Tank in the chest does its direct hit AND its explosion, which is the
			difference between a good shot and a panicked one. `endPosition` is
			already the right point — the last thing the pierce hit, or the end of
			the ray if it hit nothing, which is a rocket sailing past and going off
			on the wall behind.

			Inside the pellet loop rather than after it, so a hypothetical
			multi-pellet launcher would explode once per pellet rather than once
			for the volley. Nothing in the roster does that today; the alternative
			reads as if it could not.

			ProjectileService owns explosions — the camera falloff, the atmosphere
			flash and the gib rule are what make one read as an explosion, and they
			are not per-weapon decisions. Absent, the shot is simply a bullet: this
			must never be the reason a round fails to fire.
		]]
		if definition.blastRadius and definition.blastDamage then
			local projectiles = Registry.find("ProjectileService")
			if projectiles and typeof(projectiles.detonate) == "function" then
				projectiles:detonate(
					shooter,
					endPosition,
					definition.blastRadius,
					definition.blastDamage,
					weaponId
				)
			end
		end
	end

	--[[
		And the pogo, for the two weapons that have one.

		OUTSIDE the pellet loop, unlike the blast above it, and the difference is
		deliberate: a blast per pellet is a hypothetical multi-pellet launcher
		exploding once per pellet, which is arguably right. A launch per pellet
		is a shotgun-shaped pogo weapon throwing its user into orbit for one
		trigger pull, which is not.

		Guarded like the blast is. Absent, the shot is simply a bullet — this must
		never be the reason a round fails to fire.
	]]
	if definition.pogo and pogoAt then
		local pogo = Registry.find("PogoService")
		if pogo and typeof(pogo.launch) == "function" then
			pogo:launch(shooter, definition.pogo, pogoAt, pogoHit)
		end
	end

	return records
end

Registry.register("BallisticsService", BallisticsService)

return BallisticsService
