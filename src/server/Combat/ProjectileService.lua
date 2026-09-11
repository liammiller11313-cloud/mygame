--!nonstrict
--[[
	ProjectileService — the three things you throw.

	Pipe bombs, molotovs and hazardous waste are placed in the map or by
	ItemPlacer, picked up by InventoryService and drawn in the HUD, and until
	this module existed none of them could ever be used: InputController sent
	Remotes.Event.ThrowItem and nobody was listening. This is the listener.

	── WHAT EACH ONE IS FOR ────────────────────────────────────────────────────
	They are not three flavours of grenade. Each answers a different problem, and
	a team that reads which one they are holding correctly survives a wave they
	otherwise would not.

	  PIPE BOMB  deletes a horde by MOVING it first. Every common inside a wide
	             radius abandons the survivors and runs at the beeping light, and
	             then the light goes away and so do they. The gathering is the
	             whole item: a pipe bomb thrown at a wall you are backing away
	             from buys ten seconds that no amount of ammunition can.
	  MOLOTOV    denies ground. It is not damage, it is a wall you can put
	             anywhere, and it is the intended counter to a Tank —
	             InfectedConfig gives a Tank burnDamagePerSecond 150 against 4000
	             health precisely so that a Tank walking through fire is a Tank
	             the team can beat.
	  HAZARDOUS  moves a horde the way a pipe bomb does, but slowly and for a
	  WASTE      long time: fifty seconds of split drum that the wave walks to
	             and stands in. That length is the item. A pipe bomb is thrown at
	             a horde already on you; this is put down BEFORE one, on the
	             corridor you have decided not to defend, and it is still running
	             when the wave it was meant for arrives. See the ZONES table.

	── AUTHORITY ───────────────────────────────────────────────────────────────
	The client sends an origin, a direction and a power, and every one of those
	is a suggestion. The origin is checked against where the server thinks the
	thrower's head is (GameConfig.HitValidation.PositionTolerance) and replaced
	when it is out of tolerance rather than rejected — a laggy player still gets
	their throw, they just do not get to pick where it comes from. The item comes
	out of the inventory through InventoryService:consumeSlot, which is what
	proves they were holding it at all.

	── DAMAGE ──────────────────────────────────────────────────────────────────
	Nothing here touches a Humanoid. The blast goes through
	DamageService:applyExplosion (which is what makes GoreConfig's
	ExplosiveAlwaysGibs true of everything a pipe bomb kills), fire on infected
	goes through InfectedService:ignite (which owns the burn, its damage and its
	kill credit), and fire on survivors goes through DamageService:applyDamage
	like any other source.

	── PERFORMANCE AND CLEANUP ─────────────────────────────────────────────────
	One Heartbeat connection drives every live projectile, every fire pool and
	every lure zone. Contact is a swept raycast between steps rather than a
	.Touched connection per object, the area effects re-test bodies four times a
	second rather than every frame off ONE shared list of the living, and every
	instance any of this creates belongs to a Trove that is destroyed on a hard
	deadline. A molotov that leaks its fire parts would still be burning through
	the framerate two waves later.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local AudioConfig = require(Shared.Config.AudioConfig)
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local GoreConfig = require(Shared.Config.GoreConfig)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local RaycastUtil = require(Shared.Util.RaycastUtil)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local RigUtil = require(Shared.Util.RigUtil)
local Trove = require(Shared.Util.Trove)
local Types = require(Shared.Types)
local UITheme = require(Shared.Config.UITheme)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local THROWABLE = Enums.Throwable
local VALIDATION = GameConfig.HitValidation
local COLOR = UITheme.Color

--[[
	Throwables have no config module of their own. That is deliberate: they are
	three items rather than a roster, and every number below governs behaviour
	that is only visible in this file. Anything that DOES already have an owner —
	blast falloff, burn damage per second, friendly fire, the gore roll, how far
	a Common can hear — is read from the config that owns it and never restated.
]]

-- A player can only throw what they are holding, so this is anti-spam on the
-- remote rather than balance: without it a client can ask several hundred times
-- a second and make the server do the inventory walk every time.
local THROW_INTERVAL = 0.4

-- Hard ceiling on objects in flight. Unreachable in a real round (one throwable
-- per survivor), so hitting it means something is wrong and the oldest is
-- retired rather than the newest refused.
--[[ How far in front of the eye a fired round is placed. Far enough not to be
     inside the shooter's own head for a frame, and the first swept ray covers
     the gap regardless — see launch. ]]
local ROUND_SPAWN_AHEAD = 3

--[[
	Raised from 12, and the number stopped being arbitrary when the paintball
	became a real projectile.

	Twelve was sized for throwables: four survivors cannot have more than a few
	molotovs and pipe bombs in the air at once, and a rocket is one round every
	three seconds. A semi-automatic paintball is a different shape of demand
	entirely. Five a second each, a three-second life, GameConfig.MaxSurvivors of
	4 — sixty in the air if the whole team empties its magazines into open sky at
	the same moment and not one ball hits anything.

	Which is the number this is deliberately just UNDER. Sixty is the ceiling of
	a case that does not happen: a ball at two hundred studs a second covers six
	hundred studs before it times out, so in a real fight almost every one is
	gone in a fifth of a second and the live count sits in single figures.
	Fifty-six buys the whole realistic range and leaves the pathological case to
	evict its own oldest ball, which is exactly what _evictOldest is for.

	Sixty cheap parts is nothing. Sixty parts EVICTING a lit pipe bomb is the
	thing that mattered, and that is the other half of _evictOldest.
]]
local MAX_LIVE_PROJECTILES = 56

--[[ How far an impact effect is worth sending. The same cull distance
     BallisticsService and MeleeService use for theirs, read from the same place,
     so a paint splat and a bullet mark appear and stop appearing together. ]]
local EFFECT_RADIUS = GoreConfig.Budget.CullDistance

-- Muzzle velocity at power 1, plus the lob that makes a throw arc instead of
-- travelling like a bullet. The lift is what lets a player put one over a car.
local THROW_SPEED = 86
local THROW_LIFT = 16
local THROW_TUMBLE = 9 -- rad/s of spin, purely so it reads as thrown
local THROW_FORWARD_OFFSET = 2.2 -- spawned clear of the thrower's own shoulder

-- Nothing lives forever. A throwable that somehow never lands is still gone by
-- this point, and the fuse timers below are all well under it.
local MAX_FLIGHT_TIME = 12

-- The area effects re-test bodies at this rate off one shared list of the
-- living. Four times a second is imperceptible for walking into fire and a
-- fifteenth of the work of doing it every frame.
local ZONE_INTERVAL = 0.25

-- ── pipe bomb ───────────────────────────────────────────────────────────────

local PIPE_FUSE = 4.4

--[[ The lure radius is a Common's own hearing range, so the promise the item
     makes is exactly "every infected that could have heard you can hear this
     instead". Retuning how far a horde hears retunes the pipe bomb with it. ]]
local COMMON_DEFINITION = InfectedConfig.get(Enums.Infected.Common)
local PIPE_LURE_RADIUS = if COMMON_DEFINITION then COMMON_DEFINITION.hearingRange else 320

-- Re-issued rather than set once: commons that spawn, or that finish being
-- staggered, during the fuse have to join the crowd too, and the bomb is still
-- rolling, so the gathering point moves with it.
local PIPE_LURE_REFRESH = 0.35

--[[ Enough to erase a packed horde and to genuinely hurt a special, and not
     remotely enough to threaten a Tank — fire is the answer to a Tank, and a
     pipe bomb that also solved that problem would flatten the whole item
     triangle. Falloff to nothing at the rim is DamageService's. ]]
local PIPE_BLAST_RADIUS = 34
local PIPE_BLAST_DAMAGE = 480

-- The beep accelerates from the first interval to the last across the fuse.
-- This is the entire readout: how long you have, and where they are all going.
local PIPE_BEEP_SLOW = 0.6
local PIPE_BEEP_FAST = 0.08
local PIPE_LIGHT_RANGE = 26
local PIPE_LIGHT_BRIGHTNESS = 4

local PIPE_FLASH_TIME = 0.32
local PIPE_SHAKE_RADIUS = 90 -- studs within which the blast moves the camera
local PIPE_SHAKE_POSITION = 3.4
local PIPE_SHAKE_ROTATION = 5.0
local PIPE_SHAKE_DECAY = 9
local PIPE_ATMOSPHERE_FLASH = 0.35

-- ── molotov ─────────────────────────────────────────────────────────────────

-- A jar that never hits anything still breaks; glass does.
local MOLOTOV_FUSE = 8

--[[ The pool is the item. Twenty-two seconds is long enough to be a decision
     about ground rather than a burst of damage, and short enough that a team
     can take the corridor back before the wave that needed it is over. ]]
local FIRE_LIFETIME = 22
local FIRE_RADIUS_START = 7
local FIRE_RADIUS_MAX = 21
local FIRE_SPREAD_TIME = 3.5
local FIRE_HEIGHT = 9 -- vertical reach; fire on the floor below must not burn you

--[[ Survivors burn too, and that is not an oversight — a molotov you cannot
     stand in is what makes it a wall.

     ONLY THE THROWER, THOUGH, AND THIS USED TO CLAIM OTHERWISE. The fire tick
     names the thrower as the attacker, so for anybody ELSE DamageService takes
     its FriendlyFireEnabled == false branch and blocks the damage outright,
     before the difficulty's friendly-fire scale is ever reached. The scale this
     comment described as quartering the burn on Normal only ever applies to the
     person who threw it, who is deliberately not protected from their own fire.
     So a molotov is a wall to you and to the horde, and a warm inconvenience to
     your team. Infected are NOT damaged from here: InfectedService:ignite owns burning,
     including the 150/s that makes fire the answer to a Tank. ]]
local FIRE_SURVIVOR_DPS = 34

-- Ceiling on simultaneous pools. The oldest is retired rather than a new throw
-- refused, because an item the player spent must always do something.
local MAX_FIRE_POOLS = 4
local FIRE_CELLS = 9

local FIRE_COLOR = Color3.fromRGB(255, 148, 48)
local FIRE_SECONDARY_COLOR = Color3.fromRGB(180, 42, 16)
local FIRE_CELL_SIZE = 5.5
local FIRE_CELL_HEAT = 12
local FIRE_LIGHT_RANGE = 30
local FIRE_LIGHT_BRIGHTNESS = 2.6
local FIRE_FADE_TIME = 2.5 -- the pool dies down rather than blinking out

-- ── the lure zone: the hazardous waste ──────────────────────────────────────

--[[
	ONE ITEM, AND A MACHINE BUILT FOR MORE THAN ONE.

	This used to be two — the bile jar and the waste — and the jar is gone. It
	was replaced rather than joined: both put a puddle on the floor that the
	horde walks to, and two items that do that are one item and a copy of it.

	What survived is the interesting half:

	  HAZARDOUS     a plan. Long, wide, and it coats NOBODY. It pulls the wave to
	  WASTE         a PLACE and holds it there for the best part of a minute,
	                which is a thing you do BEFORE the wave arrives: bait a
	                corridor you are not defending, buy a route to the safe room,
	                or feed a crowd into a molotov you already threw.

	The jar's other half — coating a survivor so the horde comes for the PERSON
	rather than the spot — went with it, and was never really this file's to
	begin with. That is the Boomer's whole identity, the Boomer still does it,
	and doing it from a floor item as well made the Boomer less frightening.
	See SurvivorService:applyBile.

	Still one table per kind rather than a set of constants, because the machine
	below is general and the shape of a second zone is a table rather than a
	branch. The fields are the whole vocabulary: anything a future zone wants to
	differ in is a row here.
]]
local ZONES = table.freeze({
	[THROWABLE.HazardousWaste] = table.freeze({
		--[[ A long fuse, because this is a drum rather than a bottle and it
		     should feel thrown rather than lobbed — and because an item used to
		     prepare ground wants to be placeable at range. ]]
		fuse = 10,
		--[[ Fifty seconds. This is the number that makes it the item it is:
		     long enough to still be running when the wave it was put down for
		     arrives, which is the entire use. It is paid for twice — a
		     sixty-second respawn in MapConfig, and the same four-zone ceiling
		     every other pool shares. ]]
		duration = 50,
		-- Wide, because it is aimed at a doorway rather than at a person, and a
		-- zone you place in advance has to cover the ground you are giving up.
		splashRadius = 22,
		height = 14,
		poolSize = 18,
		cells = 11,
		--[[ These are server-side emitters on a replicated part: every client
		     renders them at whatever rate is set here, so a phone cannot scale
		     them the way GoreConfig.budgetFor scales a blood burst. They have to
		     be affordable on the weakest device in the server.

		     At 26 with a leak on top, four zones put about 450 large soft
		     particles on screen — three and a half times anything else this
		     system does, on a zone that lasts fifty seconds, so four at once is
		     likely rather than exotic. 14 plus a thin leak is 183. ]]
		mistRate = 14,
		color = COLOR.Hazard,
		--[[ The leak, on top of the mist. A drum that has split is still
		     emptying, so this drifts UP and keeps going for the whole fifty
		     seconds rather than settling like a splash — it is the part that
		     reads at distance through a doorway, and from across a street it is
		     the entire tell.

		     Stated rather than left nil, like every field here: a misspelled one
		     is then a missing row rather than an effect that quietly does not
		     happen. ]]
		leaks = true,
	}),
})

-- What an unrecognised throwable waits before landing. Only reachable through
-- the fallback in _detonate; see the note there.
local UNKNOWN_FUSE = 8

local ZONE_LURE_RADIUS = PIPE_LURE_RADIUS -- who comes running; the same earshot
local ZONE_LURE_REFRESH = 0.5
local ZONE_FADE_TIME = 2.0

--[[ Same ceiling and same reasoning as the fire pools: the oldest zone is
     retired rather than a thrown item refused. It is a ceiling on ZONES rather
     than on a kind, so a second lure item shares this budget rather than
     doubling it — the cost is frame time, and a frame does not care which item
     made the puddle. Four of these is 183 particles; see mistRate. ]]
local MAX_ZONES = 4

-- ── shared visuals ──────────────────────────────────────────────────────────

-- Engine textures rather than marketplace assets: they ship with every client
-- and cannot fail to load mid-round.
local SMOKE_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
local SPARK_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"

local GROUND_SEARCH = 24 -- how far down a shatter looks for a floor to sit on

local EPSILON = 1e-4

--[[
	The bank has no explosion, no glass-shatter and no beep sample yet. Rather
	than stay silent, each of these borrows the closest thing in AudioConfig.Id
	and re-shapes it: a shotgun blast dropped more than an octave reads as an
	explosion, and the impact-glass sample is already exactly a bottle breaking.
	When real samples are uploaded, only the ids here change.
]]
local function localSound(
	id: string,
	volume: number,
	pitchMin: number,
	pitchMax: number,
	rollOffMax: number,
	priority: number
)
	return {
		id = id,
		ids = nil,
		volume = volume,
		pitchMin = pitchMin,
		pitchMax = pitchMax,
		rollOffMin = 12,
		rollOffMax = rollOffMax,
		looped = false,
		priority = priority,
	}
end

local SOUND = table.freeze({
	Explosion = localSound(AudioConfig.Id.ShotgunBlast, 1.0, 0.42, 0.5, 900, 9),
	Beep = localSound(AudioConfig.Id.PromptAppear, 0.55, 1.5, 1.55, 150, 5),
	Shatter = AudioConfig.Impact.Glass,
	HordeCall = AudioConfig.Infected.CommonAlert,
})

local random = Random.new()

local ProjectileService = {}

ProjectileService._trove = Trove.new()
ProjectileService._folder = nil :: Folder?
ProjectileService._live = {} :: { any }
ProjectileService._fires = {} :: { any }
ProjectileService._zones = {} :: { any }
ProjectileService._lastThrow = {} :: { [Player]: number }
ProjectileService._zoneAccumulator = 0

-- ════════════════════════════════════════════════════════════════════════════
--  Small helpers
-- ════════════════════════════════════════════════════════════════════════════

local function isFiniteVector(value: any): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	return value.X == value.X and value.Y == value.Y and value.Z == value.Z and value.Magnitude < math.huge
end

local function audio(): any?
	return Registry.find("AudioService")
end

local function playAt(definition: any, position: Vector3)
	local service = audio()
	if service then
		service:playAt(definition, position)
	end
end

--[[ Distance in the plane, with height treated separately. A fire pool on the
     floor below has to be harmless, and a straight radius check would set light
     to somebody standing on the walkway above it. ]]
local function withinColumn(from: Vector3, to: Vector3, radius: number, height: number): boolean
	local delta = to - from
	if math.abs(delta.Y) > height then
		return false
	end
	local flat = Vector3.new(delta.X, 0, delta.Z)
	return flat.Magnitude <= radius
end

--[[
	Drops a point onto whatever is under it, so a shatter puddles on the floor
	instead of hanging in the air where the bottle happened to break.

	Deliberately NOT RaycastUtil.groundAt: that one starts its cast above the
	point it is given, which indoors finds the top of the ceiling and puts the
	fire on the floor above the fight. This starts a stud over the impact — high
	enough not to begin inside the surface it just hit, low enough that the first
	thing it finds is the ground the player is standing on.

	The params are reused rather than rebuilt, the same way hasLineOfSight reuses
	its own: nothing between the filter assignment and the cast yields, so no
	other caller can observe the filter mid-cast.
]]
local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
groundParams.IgnoreWater = true
groundParams.RespectCanCollide = false

local function groundedAt(position: Vector3, ignore: { Instance }): Vector3
	groundParams.FilterDescendantsInstances = ignore
	local result =
		Workspace:Raycast(position + Vector3.yAxis, Vector3.new(0, -GROUND_SEARCH, 0), groundParams)
	return if result then result.Position else position
end

local function decorate(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Locked = true
	part.CollisionGroup = "Debris"
end

-- ════════════════════════════════════════════════════════════════════════════
--  Lifecycle
-- ════════════════════════════════════════════════════════════════════════════

function ProjectileService:init()
	self:_container()
end

--[[ One folder in Workspace holding every part this service is responsible for,
     so a developer can see at a glance what is still burning — and so a bad boot
     order can never leave a thrown object unparented and silently gone. ]]
function ProjectileService:_container(): Instance
	local folder = self._folder
	if folder and folder.Parent then
		return folder
	end

	folder = Workspace:FindFirstChild("FL_Projectiles")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "FL_Projectiles"
		folder.Parent = Workspace
	end
	self._folder = folder
	return folder
end

function ProjectileService:start()
	-- THE loop. Every projectile, every fire pool and every lure zone, forever.
	self._trove:connect(RunService.Heartbeat, function(deltaTime: number)
		self:_step(deltaTime)
	end)

	self._trove:connect(Remotes.Event.ThrowItem.OnServerEvent, function(player: Player, payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		-- itemId is deliberately not read off the payload: what the player is
		-- holding is the server's business and the client is not asked.
		self:throw(player, nil, payload.origin, payload.direction, payload.power)
	end)

	self._trove:connect(Players.PlayerRemoving, function(player: Player)
		self._lastThrow[player] = nil
	end)
end

-- ════════════════════════════════════════════════════════════════════════════
--  Throwing
-- ════════════════════════════════════════════════════════════════════════════

--[[
	Throws whatever the player is holding in their throwable slot.

	`itemId`, `origin`, `direction` and `power` are all optional: InventoryService
	calls this with nothing but the item id when the throw key is pressed on an
	already-equipped throwable, and the remote calls it with everything but the
	id. Anything missing is taken from the server's own view of the character.

	Returns true only when an object actually left the hand and the item was
	spent, because InventoryService clears the slot on that answer.
]]
function ProjectileService:throw(
	player: Player,
	itemId: string?,
	origin: Vector3?,
	direction: Vector3?,
	power: number?
): boolean
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false
	end

	local now = os.clock()
	local last = self._lastThrow[player]
	if last and now - last < THROW_INTERVAL then
		return false
	end

	local survivors = Registry.find("SurvivorService")
	if survivors then
		if not survivors:isAlive(player) or survivors:isIncapacitated(player) then
			return false
		end
	end

	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return false
	end
	local muzzle = if head and head:IsA("BasePart") then head.Position else root.Position

	local inventory = Registry.find("InventoryService")
	if not inventory then
		return false
	end

	local held = inventory:getItem(player, Enums.Slot.Throwable)
	if typeof(held) ~= "string" or THROWABLE[held] == nil then
		return false
	end
	-- A caller that named an item has to have named the one being held. Nothing
	-- in the game can throw a molotov out of a pipe bomb's slot.
	if itemId ~= nil and itemId ~= held then
		return false
	end

	--[[ Out of tolerance is not cheating so much as latency, and dropping the
	     throw would cost the player an item they will swear they threw. The
	     claim is replaced with the server's own muzzle instead. ]]
	local from = muzzle
	if isFiniteVector(origin) then
		local claimed = origin :: Vector3
		if (claimed - muzzle).Magnitude <= VALIDATION.PositionTolerance then
			from = claimed
		end
	end

	local aim = root.CFrame.LookVector
	if isFiniteVector(direction) then
		local aimed = direction :: Vector3
		if aimed.Magnitude > EPSILON then
			aim = aimed.Unit
		end
	end

	local strength = 1
	if typeof(power) == "number" and power == power then
		strength = math.clamp(power, 0, 1)
	end

	-- The spend is the last thing that can fail. If it does, they were not
	-- holding it and nothing was created.
	if not inventory:consumeSlot(player, Enums.Slot.Throwable, held) then
		return false
	end

	self._lastThrow[player] = now
	self:_spawnProjectile(player, held, from + aim * THROW_FORWARD_OFFSET, aim, strength, character)
	return true
end

--[[ The thrown object itself. A pipe bomb bounces (it is a pipe, and rolling to
     the wrong place is part of the risk); a bottle does not survive its first
     contact, so it is left non-collidable and the swept raycast in _step is the
     only thing that stops it. ]]
--[[
	Fires a round that travels, for the one weapon that does.

	── WHY THIS LIVES HERE AND NOT IN BALLISTICSSERVICE ────────────────────────
	Everything a flying round needs already exists in this file and nowhere else:
	a stepped list with a live cap, a swept-ray contact test that does not miss
	fast movers the way .Touched does, and a detonation that produces the exact
	explosion every other blast in the game produces. Building a second flight
	loop next to this one would mean two answers to "what does an explosion look
	like", and they would drift.

	BallisticsService still owns the SHOT — it validated the shooter, spent the
	ammunition, told the other clients and played the report. This owns only what
	happens between the muzzle and the bang.

	`spec` is the weapon's ProjectileProfile; `radius` and `damage` are its
	ordinary blastRadius and blastDamage, so a travelling launcher and a hitscan
	one are tuned in the same two fields and read the same way.

	`contact` is for a round that does NOT explode — the classic paintball, which
	travels like a rocket and lands like a bullet. Nil means the round detonates,
	which is what a launcher does and what every caller did before it existed.
	When present it carries `damage` (single target, where it actually hit),
	`paint` (the weapon's PaintProfile) and `tint` (this shot's colour, which is
	also the colour of the ball in flight — a paintball that flew green and
	landed pink would read as two different objects).
]]
function ProjectileService:launch(
	owner: Player,
	weaponId: string,
	origin: Vector3,
	direction: Vector3,
	spec: any,
	radius: number,
	damage: number,
	character: Model?,
	contact: any?
)
	if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" or direction.Magnitude <= EPSILON then
		return
	end
	if typeof(spec) ~= "table" or typeof(radius) ~= "number" or typeof(damage) ~= "number" then
		return
	end
	if #self._live >= MAX_LIVE_PROJECTILES then
		self:_evictOldest()
	end

	local unit = direction.Unit
	local trove = Trove.new()

	--[[
		Born a little in FRONT of the eye, and the swept ray still starts AT it.

		The shot comes from the camera, and a round that appears exactly there is
		one frame of a rocket inside the shooter's own head. So the body is placed
		ahead — but `lastPosition` below stays at the true origin, so the very
		first contact test covers the gap that was skipped.

		Without that, firing with a wall a stud in front of you would put the round
		on the far side of it and detonate in the next room. The offset is a
		visual convenience and must not be allowed to become a way through
		geometry.
	]]
	local muzzle = origin + unit * ROUND_SPAWN_AHEAD

	local body = Instance.new("Part")
	body.Name = "FL_Round_" .. weaponId
	body.Size = spec.size
	--[[ CFrame rather than Position: the round is longer than it is wide and
	     tumbles, so it has to START pointed down the shot or the first frame is a
	     rocket flying sideways. ]]
	body.CFrame = CFrame.lookAt(muzzle, muzzle + unit)
	--[[ This shot's paint over the profile's colour. See `contact` above: the
	     ball in the air and the splat it leaves are the same colour because they
	     are the same number, read once in BallisticsService from the shot seed. ]]
	body.Color = if contact and typeof(contact.tint) == "Color3" then contact.tint else spec.color
	body.Material = Enum.Material.Metal
	body.Anchored = false
	--[[ Never collides. Contact is the swept ray in _stepProjectile, which is
	     exact; letting the engine also resolve a collision would bounce the round
	     off the wall it is in the middle of detonating on. ]]
	body.CanCollide = false
	body.CanQuery = false
	body.CanTouch = false
	body.CastShadow = false
	body.Locked = true
	body.CollisionGroup = "Debris"

	--[[ The user's own model, dressing only — the procedural part stays as the
	     physics body and is simply hidden. Same rule the throwables follow, and
	     for the same reason: flight must not change with whose model is loaded. ]]
	local factory = Registry.find("PlaceholderFactory")
	local dressing = factory
		and typeof(factory.buildWeaponModel) == "function"
		and factory:buildWeaponModel(weaponId .. "Round")
	if dressing then
		body.Transparency = 1
		dressing:PivotTo(body.CFrame)
		for _, part in dressing:GetDescendants() do
			if part:IsA("BasePart") then
				--[[ Anchored outranks the weld below it: an anchored part is one
				     the engine does not move, constraint or no constraint. A
				     supplied model built in Studio, where anchoring everything is
				     the habit, would otherwise stay at the muzzle while the
				     invisible physics body flew on without it. ]]
				part.Anchored = false
				part.Massless = true
				part.CanCollide = false
				part.CanQuery = false
				part.CanTouch = false
				part.CollisionGroup = "Debris"
				local hold = Instance.new("WeldConstraint")
				hold.Part0 = body
				hold.Part1 = part
				hold.Parent = part
			end
		end
		dressing.Parent = body
	end

	body.Parent = self:_container()
	trove:add(body)

	--[[ Its own weight, cancelled. A force rather than a property because the
	     mass is only knowable once the part exists and its dressing is welded on
	     — the same reason the classic slingshot's pellet does it this way. See
	     ProjectileProfile. ]]
	if spec.gravity == false then
		local lift = Instance.new("BodyForce")
		lift.Name = "FL_NoDrop"
		lift.Force = Vector3.new(0, body.AssemblyMass * Workspace.Gravity, 0)
		lift.Parent = body
	end

	body.AssemblyLinearVelocity = unit * spec.speed
	body.AssemblyAngularVelocity = Vector3.new(
		random:NextNumber(-1, 1),
		random:NextNumber(-1, 1),
		random:NextNumber(-1, 1)
	) * spec.spin

	-- Server-owned, like every other projectile here: where it goes off is a
	-- damage decision and not the shooter's to make.
	pcall(function()
		body:SetNetworkOwner(nil)
	end)

	local ignore: { Instance } = { body }
	if character then
		table.insert(ignore, character)
	end

	table.insert(self._live, {
		--[[ No `kind`. A kind is a THROWABLE id and items.py checks that every one
		     of those is named in _detonate; a fired round is not a throwable, has
		     no map family and no inventory slot, and borrowing an id would make it
		     look like one to every tool that reads them. `rocket` is what it is,
		     and _detonate branches on that first. ]]
		rocket = { weaponId = weaponId, radius = radius, damage = damage, contact = contact },
		owner = owner,
		body = body,
		light = nil,
		trove = trove,
		params = RaycastUtil.excluding(ignore),
		-- The EYE, not the muzzle. See the offset above.
		lastPosition = origin,
		--[[ Kept apart from lastPosition, which moves every step. A contact round
		     reports how far it travelled, and that is measured from where it was
		     fired rather than from where it was one frame ago. ]]
		spawnOrigin = origin,
		--[[ The way it was pointed when it left. Used only as the fallback for a
		     contact round's travel direction: the live reading is the step it
		     just took, and a step of zero length has no direction to normalise. ]]
		heading = unit,
		spawnedAt = os.clock(),
		endsAt = os.clock() + spec.lifetime,
		lureAt = 0,
		beepAt = 0,
		lit = false,
		shattersOnContact = true,
	})
end

function ProjectileService:_spawnProjectile(
	owner: Player,
	kind: string,
	position: Vector3,
	aim: Vector3,
	strength: number,
	character: Model?
)
	if #self._live >= MAX_LIVE_PROJECTILES then
		self:_evictOldest()
	end

	local trove = Trove.new()
	local bounces = kind == THROWABLE.PipeBomb

	local body = Instance.new("Part")
	body.Name = "FL_Throwable_" .. kind
	body.Shape = Enum.PartType.Cylinder
	body.Size = Vector3.new(1.5, 0.5, 0.5)
	body.CFrame = CFrame.new(position)
	body.Anchored = false
	body.CanCollide = bounces
	body.CanQuery = false
	body.CanTouch = false
	body.CastShadow = false
	body.Locked = true
	body.CollisionGroup = "Debris"
	-- Elastic enough to bounce off a wall and rough enough to stop rolling; a
	-- pipe bomb that skates across the whole room is a pipe bomb nobody can aim.
	body.CustomPhysicalProperties = PhysicalProperties.new(2.5, 0.6, 0.35, 1, 1)

	local light: PointLight? = nil
	--[[ The pipe bomb's blinking head, kept so a supplied model can hide it. See
	     the dressing block below: the LIGHT is gameplay and stays either way, the
	     little neon ball it hangs on is only there because the grey-box needs
	     something to be. ]]
	local lampPart: BasePart? = nil

	if kind == THROWABLE.PipeBomb then
		body.Color = COLOR.BorderBright
		body.Material = Enum.Material.Metal

		local lamp = Instance.new("Part")
		lamp.Name = "Light"
		lamp.Shape = Enum.PartType.Ball
		lamp.Size = Vector3.new(0.4, 0.4, 0.4)
		lamp.Color = COLOR.Danger
		lamp.Material = Enum.Material.Neon
		lamp.CFrame = body.CFrame * CFrame.new(0.85, 0, 0)
		lamp.Anchored = false
		lamp.CanCollide = false
		lamp.CanQuery = false
		lamp.CanTouch = false
		lamp.CastShadow = false
		lamp.Locked = true
		lamp.Massless = true
		lamp.CollisionGroup = "Debris"
		lamp.Parent = body
		lampPart = lamp

		local weld = Instance.new("WeldConstraint")
		weld.Part0 = body
		weld.Part1 = lamp
		weld.Parent = body

		--[[ The light is not decoration. The map is dark by wave four and the
		     crowd running at the bomb is the payoff of the whole item; without
		     something lighting them, the best moment in the game happens in the
		     dark and nobody sees it. ]]
		local glow = Instance.new("PointLight")
		glow.Color = COLOR.Danger
		glow.Range = PIPE_LIGHT_RANGE
		glow.Brightness = PIPE_LIGHT_BRIGHTNESS
		glow.Shadows = false
		glow.Parent = lamp
		light = glow
	elseif kind == THROWABLE.Molotov then
		body.Color = COLOR.Warning
		body.Material = Enum.Material.Glass
	else
		--[[ In flight it wears the colour of the puddle it will become, so a
		     player who sees one arc past a doorway already knows what is about
		     to be on the floor. See the ZONES header. ]]
		local inFlight = ZONES[kind]
		body.Color = if inFlight then inFlight.color else COLOR.Hazard
		body.Material = Enum.Material.Neon
	end

	--[[
		The user's own model, when they have supplied one.

		Dressing only: the procedural part stays and keeps being the physics body,
		it is simply made invisible. That is deliberate rather than lazy — the
		bounce of a pipe bomb is tuned on this part's CustomPhysicalProperties and
		its collision shape, and a supplied model whose geometry decided how it
		skidded would make every user's bombs handle differently from every
		other's.

		Everything hung on it is massless and non-collidable for the same reason,
		and non-queryable because a bottle in flight that stops a bullet meant for
		the Common behind it is the worst kind of bug: invisible, and it costs a
		kill.

		Attached BEFORE the velocity below. Welding into an assembly after its
		velocity is assigned invites the engine to recompute the body around the
		new mass and lose the throw.
	]]
	local factory = Registry.find("PlaceholderFactory")
	local dressing = factory
		and typeof(factory.buildThrowableModel) == "function"
		and factory:buildThrowableModel(kind)
	if dressing then
		body.Transparency = 1
		--[[ The light survives, its neon ball does not: a real pipe bomb model
		     carries its own head, and a spare glowing sphere parked where the
		     grey-box's used to be would be floating beside it. ]]
		if lampPart then
			lampPart.Transparency = 1
		end
		dressing:PivotTo(body.CFrame)
		for _, part in dressing:GetDescendants() do
			if part:IsA("BasePart") then
				--[[ Anchored outranks the weld below it: an anchored part is one
				     the engine does not move, constraint or no constraint. A
				     supplied model built in Studio, where anchoring everything is
				     the habit, would otherwise stay at the muzzle while the
				     invisible physics body flew on without it. ]]
				part.Anchored = false
				part.Massless = true
				part.CanCollide = false
				part.CanQuery = false
				part.CanTouch = false
				part.CollisionGroup = "Debris"
				local hold = Instance.new("WeldConstraint")
				hold.Part0 = body
				hold.Part1 = part
				hold.Parent = part
			end
		end
		dressing.Parent = body
	end

	body.Parent = self:_container()
	trove:add(body)

	body.AssemblyLinearVelocity = aim * (THROW_SPEED * strength) + Vector3.yAxis * THROW_LIFT
	body.AssemblyAngularVelocity = Vector3.new(
		random:NextNumber(-1, 1),
		random:NextNumber(-1, 1),
		random:NextNumber(-1, 1)
	) * THROW_TUMBLE

	-- Server-owned physics. A client that owned its own grenade could stop it in
	-- mid-air, and the blast position is a damage decision.
	pcall(function()
		body:SetNetworkOwner(nil)
	end)

	--[[ Built once per throw rather than per step: the ignore list never changes
	     for the life of the object, and a fresh RaycastParams sixty times a
	     second per projectile is exactly the allocation this codebase forbids. ]]
	local ignore: { Instance } = { body }
	if character then
		table.insert(ignore, character)
	end
	local params = RaycastUtil.excluding(ignore)

	--[[ Named rather than defaulted. Every one of these dispatches used to end
	     in an `else` that meant the lure zone, so a throwable added to the enum
	     and to nothing else silently became one with a different model — it
	     would look wired up, place in the map, throw, and land as the wrong
	     item. scripts/items.py fails the build on a throwable this file never
	     names, and that check exists because this is where it would have been
	     missed. ]]
	local spec = ZONES[kind]
	local fuse = if kind == THROWABLE.PipeBomb
		then PIPE_FUSE
		elseif kind == THROWABLE.Molotov then MOLOTOV_FUSE
		elseif spec then spec.fuse
		else UNKNOWN_FUSE

	table.insert(self._live, {
		kind = kind,
		owner = owner,
		body = body,
		light = light,
		trove = trove,
		params = params,
		lastPosition = position,
		spawnedAt = os.clock(),
		endsAt = os.clock() + fuse,
		lureAt = 0,
		beepAt = 0,
		lit = false,
		-- A bottle ends on its first contact; a pipe bomb ends on its fuse and
		-- contact only decides where it rolls to next.
		shattersOnContact = not bounces,
	})
end

-- ════════════════════════════════════════════════════════════════════════════
--  The shared loop
-- ════════════════════════════════════════════════════════════════════════════

function ProjectileService:_step(deltaTime: number)
	local now = os.clock()

	local live = self._live
	for index = #live, 1, -1 do
		self:_stepProjectile(live[index], index, now)
	end

	self._zoneAccumulator += deltaTime
	if self._zoneAccumulator >= ZONE_INTERVAL then
		local elapsed = self._zoneAccumulator
		self._zoneAccumulator = 0
		self:_stepZones(now, elapsed)
	end
end

function ProjectileService:_stepProjectile(record: any, index: number, now: number)
	local body = record.body
	if not body or not body.Parent then
		self:_retireProjectile(index)
		return
	end

	local position = body.Position

	if record.kind == THROWABLE.PipeBomb then
		self:_stepPipeBomb(record, position, now)
	end

	--[[ Contact is a swept ray between steps, not a .Touched connection. Touched
	     fires on a physics thread, misses fast movers, and would be one
	     connection per object for something the loop can answer exactly. ]]
	if record.shattersOnContact then
		local delta = position - record.lastPosition
		local travelled = delta.Magnitude
		if travelled > EPSILON then
			local result = Workspace:Raycast(record.lastPosition, delta, record.params)
			if result then
				--[[ The instance and the normal go through too. A blast does not
				     care what it touched — it re-finds everything in its radius —
				     but a contact round is defined by the one part it hit: that
				     part is what takes the damage and what gets painted. ]]
				self:_detonate(record, index, result.Position + result.Normal * 0.2, result)
				return
			end
		end
	end

	record.lastPosition = position

	if now >= record.endsAt or now - record.spawnedAt >= MAX_FLIGHT_TIME then
		self:_detonate(record, index, position)
	end
end

--[[ The beep, the blink and the gathering. Every one of them is a readout of the
     same number — how long is left — and they are what turn a thrown object into
     a countdown the whole team can hear. ]]
function ProjectileService:_stepPipeBomb(record: any, position: Vector3, now: number)
	local remaining = math.max(record.endsAt - now, 0)

	if now >= record.lureAt then
		record.lureAt = now + PIPE_LURE_REFRESH
		local infected = Registry.find("InfectedService")
		if infected then
			--[[ Held only until the bomb goes off. A lure that outlived the blast
			     would leave the survivors of it standing at an empty spot
			     wondering why they walked there. ]]
			infected:lure(position, PIPE_LURE_RADIUS, remaining + PIPE_LURE_REFRESH)
		end
	end

	if now >= record.beepAt then
		local alpha = 1 - math.clamp(remaining / PIPE_FUSE, 0, 1)
		record.beepAt = now + (PIPE_BEEP_SLOW + (PIPE_BEEP_FAST - PIPE_BEEP_SLOW) * alpha)
		record.lit = not record.lit
		playAt(SOUND.Beep, position)

		local light = record.light
		if light then
			light.Brightness = if record.lit then PIPE_LIGHT_BRIGHTNESS * 2.4 else PIPE_LIGHT_BRIGHTNESS
		end
	end
end

--[[ Whatever a projectile turns into when it stops being one. ]]
function ProjectileService:_detonate(record: any, index: number, position: Vector3, hit: RaycastResult?)
	local kind = record.kind
	local owner = record.owner

	--[[ A fired round, before anything that reads `kind` — it has none. Through
	     the PUBLIC detonate, which is the same call a hitscan launcher makes, so
	     a travelling rocket and the RPG-7 produce one explosion and not two that
	     drift. ]]
	local rocket = record.rocket
	if rocket then
		if rocket.contact then
			self:_impactRound(record, position, rocket, hit)
		else
			self:detonate(owner, position, rocket.radius, rocket.damage, rocket.weaponId)
		end
		--[[ And the shove, for a launcher that has one.

		     Here rather than at the trigger, which is where the hitscan path
		     fires it and where it could not stay: a rocket jump is the BLAST
		     lifting you, and a travelling rocket's blast happens a second after
		     the trigger and somewhere else. Firing it on the pull would have
		     launched the player off a rocket still in the air, in whatever
		     direction the shot was eventually going to land — which is the
		     classic move's timing inverted and its aiming removed.

		     PogoService owns whether it counts: its own maxRange is what decides
		     that a rocket which went off across the street does not move you. ]]
		local launcher = WeaponConfig.get(rocket.weaponId)
		local profile = launcher and launcher.pogo
		if profile and owner then
			local pogo = Registry.find("PogoService")
			if pogo and typeof(pogo.launch) == "function" then
				pogo:launch(owner, profile, position, true)
			end
		end
		self:_retireProjectile(index)
		return
	end

	if kind == THROWABLE.PipeBomb then
		self:_explode(owner, position)
	elseif kind == THROWABLE.Molotov then
		self:_spawnFirePool(owner, position, record.body)
	else
		--[[ A kind with no ZONES row lands as a lure zone, which is the safe
		     answer — an unknown throwable should still DO something rather than
		     vanish out of the player's hand. It cannot happen quietly, though:
		     items.py refuses to build a throwable this file does not name. ]]
		self:_spawnLureZone(owner, position, record.body, ZONES[kind] or ZONES[THROWABLE.HazardousWaste])
	end

	self:_retireProjectile(index)
end

--[[
	Room for one more, made by giving up the LEAST important thing in the air.

	This used to be `_retireProjectile(1)` — the oldest record, whatever it was.
	With a rocket every three seconds that was fine and never fired. With a
	semi-automatic paintball it fires constantly, and the oldest record is
	routinely somebody's lit pipe bomb: four seconds into its fuse, the whole
	team backing away from where it is about to go off, deleted by a teammate's
	paint pellet and never exploding at all.

	So a FIRED ROUND goes first — it is one shot out of sixty and nobody can tell
	which one went missing. Only when every live record is a throwable does this
	fall back to the oldest of those, which is the old behaviour and is now the
	case it was always meant for.
]]
function ProjectileService:_evictOldest()
	for index, record in self._live do
		if record.rocket then
			self:_retireProjectile(index)
			return
		end
	end
	self:_retireProjectile(1)
end

--[[
	A round that LANDS rather than going off.

	The classic paintball, and the reason this exists at all: it travels like a
	rocket and resolves like a bullet, and neither of the two paths already here
	could do both. `detonate` re-finds everything in a radius, which turns one
	pellet into a grenade; the hitscan path in BallisticsService resolves at the
	trigger, which is what made this gun an SMG that happened to be green.

	Deliberately the same SHAPE as the hitscan impact it replaces — flesh takes
	damage through DamageService and scenery takes paint through PaintService,
	and never both — so a paint pellet and a bullet leave the same kind of mark
	on the same kind of surface. What is different is only WHEN: a third of a
	second after the trigger, wherever the ball actually got to.
]]
function ProjectileService:_impactRound(record: any, position: Vector3, rocket: any, hit: RaycastResult?)
	local contact = rocket.contact
	local part = hit and hit.Instance
	local owner = record.owner
	local normal = if hit then hit.Normal else Vector3.yAxis

	--[[ Nothing to resolve against. A round that reached the end of its life in
	     open air has hit nobody and painted nothing, and inventing a target
	     under it would be the pack's own invented-ground bug in a new place —
	     see PogoService for that one. ]]
	if not part or not part:IsA("BasePart") then
		return
	end

	--[[ The step it just took, which is where it was actually going. Falls back
	     to the way it was fired when that step is too short to normalise — a
	     zero-length Unit is NaN, and a NaN direction reaches GoreService and
	     decides which way a body falls. ]]
	local step = position - record.lastPosition
	local travel = if step.Magnitude > 1e-3 then step.Unit else record.heading

	local model, humanoid = RigUtil.getCharacterFromPart(part)
	if model and humanoid and RigUtil.isAlive(model) then
		local damageService = Registry.find("DamageService")
		if damageService and contact.damage > 0 then
			damageService:applyDamage(
				model,
				contact.damage,
				Types.newDamageContext({
					attacker = owner,
					weaponId = rocket.weaponId,
					damageType = Enums.DamageType.Bullet,
					region = RigUtil.getHitRegion(part),
					hitPart = part,
					hitPosition = position,
					hitNormal = normal,
					--[[ Where it was GOING, not where the shooter was standing.
					     A travelling round is the only thing in this game whose
					     direction of travel and its owner's facing can differ by
					     ninety degrees — they had a second to turn around — and
					     the direction is what decides which way a corpse falls. ]]
					direction = travel,
					distance = (position - record.spawnOrigin).Magnitude,
					piercedCount = 0,
				})
			)
		end
		return
	end

	--[[ Scenery, which is where the paint goes. PaintService answers with the
	     colour it actually put down, or nil where it refused — a puzzle prop, a
	     barricade, something too heavy to be a prop — and the client draws a
	     splat only where a real one landed. See BallisticsService, which makes
	     exactly this call for the hitscan half. ]]
	local splat: Color3? = nil
	if contact.tint and contact.paint then
		local paint = Registry.find("PaintService")
		if paint and typeof(paint.splash) == "function" then
			splat = paint:splash(part, contact.tint, contact.paint)
		end
	end

	Remotes.fireInRange("ImpactEffect", position, EFFECT_RADIUS, {
		position = position,
		normal = normal,
		material = part.Material,
		damageType = Enums.DamageType.Bullet,
		paint = splat,
	})
end

function ProjectileService:_retireProjectile(index: number)
	local record = self._live[index]
	if not record then
		return
	end
	table.remove(self._live, index)
	record.trove:destroy()
end

-- ════════════════════════════════════════════════════════════════════════════
--  Pipe bomb: the blast
-- ════════════════════════════════════════════════════════════════════════════

function ProjectileService:_explode(owner: Player?, position: Vector3)
	self:detonate(owner, position, PIPE_BLAST_RADIUS, PIPE_BLAST_DAMAGE, THROWABLE.PipeBomb)
end

--[[
	An explosion, anywhere, from anything.

	The pipe bomb was the only thing in the game that exploded, so its blast and
	its numbers were the same eighty lines. The RPG-7 needs the same blast with
	different numbers, and the wrong way to get it is a second copy that drifts —
	the camera falloff, the atmosphere flash and the gib rule are the parts that
	make an explosion read as one, and they are not per-weapon decisions.

	So the numbers are arguments and everything else is shared. `_explode` is now
	one line calling this with the pipe bomb's radius and damage.

	The SHAKE is deliberately not parameterised. A blast twenty studs away and one
	eighty studs away already differ by the falloff below; making a big explosion
	also shake harder per stud would mean the two weapons taught the player
	different things about the same distance.
]]
function ProjectileService:detonate(
	owner: Player?,
	position: Vector3,
	radius: number,
	damage: number,
	weaponId: string
)
	if typeof(position) ~= "Vector3" or typeof(radius) ~= "number" or typeof(damage) ~= "number" then
		return
	end
	if radius <= 0 or damage <= 0 then
		return
	end

	local damageService = Registry.find("DamageService")
	if damageService then
		--[[ Straight through the funnel, which is what makes GoreConfig's
		     ExplosiveAlwaysGibs true here: everything an explosion kills comes
		     apart, and the crowd it just gathered comes apart all at once. ]]
		damageService:applyExplosion(
			position,
			radius,
			damage,
			Types.newDamageContext({
				attacker = owner,
				weaponId = weaponId,
				damageType = Enums.DamageType.Explosive,
				region = Enums.HitRegion.Torso,
				hitPosition = position,
				hitNormal = Vector3.yAxis,
				sourcePosition = position,
				direction = Vector3.yAxis,
			})
		)
	end

	self:_blastEffect(position)
	playAt(SOUND.Explosion, position)

	--[[ Scaled per player rather than fired in range: a blast twenty studs away
	     and one eighty studs away are different events, and a flat shake for
	     both makes distance stop meaning anything. ]]
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root or not root:IsA("BasePart") then
			continue
		end
		local distance = (root.Position - position).Magnitude
		if distance > PIPE_SHAKE_RADIUS then
			continue
		end
		local falloff = 1 - distance / PIPE_SHAKE_RADIUS
		local away = root.Position - position
		local push = if away.Magnitude > EPSILON then away.Unit else Vector3.yAxis
		Remotes.Event.CameraImpulse:FireClient(player, {
			position = push * (PIPE_SHAKE_POSITION * falloff),
			rotation = Vector3.new(
				random:NextNumber(-1, 1),
				random:NextNumber(-1, 1),
				random:NextNumber(-1, 1)
			) * (PIPE_SHAKE_ROTATION * falloff),
			decay = PIPE_SHAKE_DECAY,
		})
	end

	-- The game is called Fading Light; an explosion is one of the few things
	-- that gets to argue with that, briefly.
	local atmosphere = Registry.find("AtmosphereService")
	if atmosphere and typeof(atmosphere.flash) == "function" then
		atmosphere:flash(PIPE_ATMOSPHERE_FLASH, 1)
	end
end

--[[ The visual. Tweened rather than stepped: the engine can interpolate a size
     and a transparency without this file spending a frame on it, and an
     explosion is over before the next zone tick would even have run. ]]
function ProjectileService:_blastEffect(position: Vector3)
	local flash = Instance.new("Part")
	flash.Name = "FL_Blast"
	flash.Shape = Enum.PartType.Ball
	flash.Size = Vector3.new(3, 3, 3)
	flash.Color = COLOR.AccentBright
	flash.Material = Enum.Material.Neon
	flash.Position = position
	decorate(flash)
	flash.Parent = self:_container()

	local glow = Instance.new("PointLight")
	glow.Color = COLOR.AccentBright
	glow.Range = PIPE_BLAST_RADIUS
	glow.Brightness = 8
	glow.Shadows = false
	glow.Parent = flash

	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = SMOKE_TEXTURE
	emitter.Color = ColorSequence.new(COLOR.AccentBright, GoreConfig.Blood.DarkColor)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 4),
		NumberSequenceKeypoint.new(1, 14),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.25),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.7, 1.5)
	emitter.Speed = NumberRange.new(24, 60)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Rate = 0
	emitter.Parent = flash

	local sparks = Instance.new("ParticleEmitter")
	sparks.Texture = SPARK_TEXTURE
	sparks.Color = ColorSequence.new(COLOR.AccentBright, COLOR.Danger)
	sparks.Size = NumberSequence.new(0.9, 0)
	sparks.Lifetime = NumberRange.new(0.3, 0.8)
	sparks.Speed = NumberRange.new(50, 110)
	sparks.SpreadAngle = Vector2.new(180, 180)
	sparks.Rate = 0
	sparks.Parent = flash

	emitter:Emit(38)
	sparks:Emit(46)

	local info = TweenInfo.new(PIPE_FLASH_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(flash, info, {
		Size = Vector3.new(1, 1, 1) * (PIPE_BLAST_RADIUS * 1.2),
		Transparency = 1,
	}):Play()
	TweenService:Create(glow, info, { Brightness = 0 }):Play()

	-- Outlives the flash by the particle lifetime so the smoke is not cut off
	-- with the ball that threw it.
	Debris:AddItem(flash, PIPE_FLASH_TIME + 2)
end

-- ════════════════════════════════════════════════════════════════════════════
--  Molotov: the fire pool
-- ════════════════════════════════════════════════════════════════════════════

function ProjectileService:_spawnFirePool(owner: Player?, position: Vector3, body: BasePart?)
	if #self._fires >= MAX_FIRE_POOLS then
		self:_retireFire(1)
	end

	local ignore: { Instance } = if body then { body } else {}
	local origin = groundedAt(position, ignore) + Vector3.new(0, 0.4, 0)

	local trove = Trove.new()
	local anchor = Instance.new("Part")
	anchor.Name = "FL_FirePool"
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Transparency = 1
	anchor.Position = origin
	decorate(anchor)
	anchor.Parent = self:_container()
	trove:add(anchor)

	local light = Instance.new("PointLight")
	light.Color = FIRE_COLOR
	light.Range = FIRE_LIGHT_RANGE
	light.Brightness = FIRE_LIGHT_BRIGHTNESS
	light.Shadows = false
	light.Parent = anchor

	--[[ The pool is a ring of cells laid out once and switched on as the fire
	     reaches them, rather than parts that move or grow. Spreading is then a
	     handful of boolean writes a second instead of a CFrame write per cell
	     per frame, and it reads exactly the same. ]]
	local cells = table.create(FIRE_CELLS)
	for index = 1, FIRE_CELLS do
		local alpha = if index == 1 then 0 else (index - 1) / (FIRE_CELLS - 1)
		local spread = FIRE_RADIUS_START + (FIRE_RADIUS_MAX - FIRE_RADIUS_START) * alpha
		local angle = random:NextNumber(0, math.pi * 2)
		local reach = if index == 1 then 0 else spread * random:NextNumber(0.55, 1)
		local offset = Vector3.new(math.cos(angle) * reach, 0, math.sin(angle) * reach)

		local cell = Instance.new("Part")
		cell.Name = "Cell"
		cell.Size = Vector3.new(2, 1, 2)
		cell.Transparency = 1
		cell.Position = groundedAt(origin + offset, ignore) + Vector3.new(0, 0.5, 0)
		decorate(cell)
		cell.Parent = anchor

		local fire = Instance.new("Fire")
		fire.Color = FIRE_COLOR
		fire.SecondaryColor = FIRE_SECONDARY_COLOR
		fire.Size = FIRE_CELL_SIZE
		fire.Heat = FIRE_CELL_HEAT
		fire.Enabled = index == 1
		fire.Parent = cell

		cells[index] = { fire = fire, spread = if index == 1 then 0 else reach }
	end

	playAt(SOUND.Shatter, origin)

	table.insert(self._fires, {
		owner = owner,
		origin = origin,
		trove = trove,
		light = light,
		cells = cells,
		startedAt = os.clock(),
		endsAt = os.clock() + FIRE_LIFETIME,
		radius = FIRE_RADIUS_START,
	})
end

function ProjectileService:_stepFire(record: any, index: number, now: number, elapsed: number, bodies: any)
	if now >= record.endsAt then
		self:_retireFire(index)
		return
	end

	local age = now - record.startedAt
	local alpha = math.clamp(age / FIRE_SPREAD_TIME, 0, 1)
	record.radius = FIRE_RADIUS_START + (FIRE_RADIUS_MAX - FIRE_RADIUS_START) * alpha

	for _, cell in record.cells do
		if not cell.fire.Enabled and cell.spread <= record.radius then
			cell.fire.Enabled = true
		end
	end

	--[[ The last seconds are a burn-down, not a switch. A pool that vanishes on
	     a frame boundary tells the team the ground is safe before it looks it,
	     which is how somebody walks into the last two seconds of a molotov. ]]
	local remaining = record.endsAt - now
	if remaining <= FIRE_FADE_TIME then
		local fade = math.clamp(remaining / FIRE_FADE_TIME, 0, 1)
		record.light.Brightness = FIRE_LIGHT_BRIGHTNESS * fade
		for _, cell in record.cells do
			cell.fire.Size = FIRE_CELL_SIZE * fade
		end
	end

	local infected = Registry.find("InfectedService")
	if infected then
		for _, model in bodies.infected do
			if withinColumn(record.origin, bodies.positions[model], record.radius, FIRE_HEIGHT) then
				--[[ ignite, never damage. InfectedService owns burning: it
				     applies the per-kind burnDamagePerSecond, keeps the flame on
				     the body, and credits the kill to whoever lit it. ]]
				infected:ignite(model, record.owner)
			end
		end
	end

	local damage = Registry.find("DamageService")
	if damage then
		for _, entry in bodies.survivors do
			if not withinColumn(record.origin, entry.position, record.radius, FIRE_HEIGHT) then
				continue
			end
			damage:applyDamage(
				entry.character,
				FIRE_SURVIVOR_DPS * elapsed,
				Types.newDamageContext({
					attacker = record.owner,
					weaponId = THROWABLE.Molotov,
					damageType = Enums.DamageType.Fire,
					region = Enums.HitRegion.Torso,
					hitPosition = entry.position,
					hitNormal = Vector3.yAxis,
					--[[ The pool, not the person who threw it. The arrow has to
					     point at the thing you can step out of. ]]
					sourcePosition = record.origin,
					direction = Vector3.yAxis,
				})
			)
		end
	end
end

function ProjectileService:_retireFire(index: number)
	local record = self._fires[index]
	if not record then
		return
	end
	table.remove(self._fires, index)
	record.trove:destroy()
end

-- ════════════════════════════════════════════════════════════════════════════
--  Lure zones: the gathering point
-- ════════════════════════════════════════════════════════════════════════════

--[[ One puddle, built to whichever ZONES spec was handed in. Every number a
     zone could differ in arrives through `spec` rather than being written here,
     which is what keeps this general enough for a second one. ]]
function ProjectileService:_spawnLureZone(owner: Player?, position: Vector3, body: BasePart?, spec: any)
	if #self._zones >= MAX_ZONES then
		self:_retireLureZone(1)
	end

	local ignore: { Instance } = if body then { body } else {}
	local origin = groundedAt(position, ignore) + Vector3.new(0, 0.2, 0)

	local trove = Trove.new()
	local anchor = Instance.new("Part")
	anchor.Name = "FL_LureZone"
	anchor.Shape = Enum.PartType.Cylinder
	anchor.Size = Vector3.new(0.3, spec.poolSize, spec.poolSize)
	-- Cylinders point down their X axis, so a puddle is one laid on its side.
	anchor.CFrame = CFrame.new(origin) * CFrame.Angles(0, 0, math.rad(90))
	anchor.Color = spec.color
	anchor.Material = Enum.Material.Neon
	anchor.Transparency = 0.35
	decorate(anchor)
	anchor.Parent = self:_container()
	trove:add(anchor)

	for _ = 1, spec.cells do
		local angle = random:NextNumber(0, math.pi * 2)
		local reach = random:NextNumber(0, spec.splashRadius * 0.8)
		local splat = Instance.new("Part")
		splat.Name = "Splat"
		splat.Shape = Enum.PartType.Cylinder
		local size = random:NextNumber(2.5, 6)
		splat.Size = Vector3.new(0.2, size, size)
		splat.CFrame = CFrame.new(
			groundedAt(origin + Vector3.new(math.cos(angle) * reach, 0, math.sin(angle) * reach), ignore)
				+ Vector3.new(0, 0.15, 0)
		) * CFrame.Angles(0, 0, math.rad(90))
		splat.Color = spec.color
		splat.Material = Enum.Material.Neon
		splat.Transparency = 0.45
		decorate(splat)
		splat.Parent = anchor
	end

	local mist = Instance.new("ParticleEmitter")
	mist.Texture = SMOKE_TEXTURE
	mist.Color = ColorSequence.new(spec.color)
	mist.Size = NumberSequence.new(6)
	mist.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.6),
		NumberSequenceKeypoint.new(1, 1),
	})
	mist.Lifetime = NumberRange.new(1.5, 3)
	mist.Rate = spec.mistRate
	mist.Speed = NumberRange.new(1, 4)
	mist.SpreadAngle = Vector2.new(60, 60)
	mist.Parent = anchor

	--[[ The second emitter, and only for a spec that asks for it. Sparks rather
	     than smoke, rising rather than spreading, and thin enough to see the
	     room through: the mist above says "there is something on the floor",
	     this says "and it is still coming out". Parented to the anchor so both
	     die with the zone on one Destroy. ]]
	if spec.leaks then
		local leak = Instance.new("ParticleEmitter")
		leak.Texture = SPARK_TEXTURE
		leak.Color = ColorSequence.new(spec.color)
		leak.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1.4),
			NumberSequenceKeypoint.new(1, 0.2),
		})
		leak.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.25),
			NumberSequenceKeypoint.new(1, 1),
		})
		leak.Lifetime = NumberRange.new(2.0, 3.8)
		--[[ Thin on purpose. A split drum venting is a stream, not a smoke
		     machine, and the thing that makes it read at distance is that it
		     RISES and is lit rather than that there is a lot of it. ]]
		leak.Rate = spec.mistRate * 0.35
		leak.Speed = NumberRange.new(3, 7)
		leak.SpreadAngle = Vector2.new(18, 18)
		-- Straight up out of the drum, and unaffected by the mist's drift.
		leak.Acceleration = Vector3.new(0, 2.5, 0)
		leak.LightEmission = 0.6
		leak.Parent = anchor
	end

	playAt(SOUND.Shatter, origin)
	-- The horde's own alert call, at the splash rather than at a survivor. It is
	-- the tell: something over there just became the most interesting thing.
	playAt(SOUND.HordeCall, origin)

	table.insert(self._zones, {
		owner = owner,
		origin = origin,
		trove = trove,
		anchor = anchor,
		mist = mist,
		startedAt = os.clock(),
		endsAt = os.clock() + spec.duration,
		lureAt = 0,
		spec = spec,
	})
end

--[[ No `bodies` parameter, unlike _stepFire. A lure zone is aimed at a floor
     and touches nobody, so it has no reason to be handed the list of the
     living — see the note at the end of the function. ]]
function ProjectileService:_stepLureZone(record: any, index: number, now: number)
	if now >= record.endsAt then
		self:_retireLureZone(index)
		return
	end

	local remaining = record.endsAt - now
	local infected = Registry.find("InfectedService")

	if infected and now >= record.lureAt then
		record.lureAt = now + ZONE_LURE_REFRESH
		--[[ Re-issued for the same reason a pipe bomb's is: commons that spawn
		     into the wave after the drum split have to come running too. The
		     hold shrinks with the puddle, so the crowd releases as it dries. ]]
		infected:lure(record.origin, ZONE_LURE_RADIUS, remaining)
	end

	if remaining <= ZONE_FADE_TIME then
		local fade = math.clamp(remaining / ZONE_FADE_TIME, 0, 1)
		record.mist.Rate = record.spec.mistRate * fade
		record.anchor.Transparency = 1 - 0.65 * fade
	end

	--[[ And that is the whole step. A lure zone never walks the survivor list:
	     it is aimed at a floor, so the only thing it does to a person is be
	     somewhere they would rather not stand.

	     The bile jar used to fork here — it coated whoever was inside it and
	     made them the horde's target — and that fork left with it. Coating a
	     survivor is the Boomer's identity and belongs to the Boomer alone; see
	     SurvivorService:applyBile, which is now the one place in the game that
	     does it. ]]
end

function ProjectileService:_retireLureZone(index: number)
	local record = self._zones[index]
	if not record then
		return
	end
	table.remove(self._zones, index)
	record.trove:destroy()
end

-- ════════════════════════════════════════════════════════════════════════════
--  Area effects, four times a second, off one list of the living
-- ════════════════════════════════════════════════════════════════════════════

--[[ Every pool and every zone tests against the SAME snapshot. Asking
     InfectedService for the horde once per pool per tick would be four walks of
     forty-six bodies where one will do, and the answer cannot change in between
     because nothing here yields. ]]
function ProjectileService:_collectBodies(): any
	local snapshot = {
		infected = {},
		positions = {},
		survivors = {},
	}

	if #self._fires > 0 then
		local infected = Registry.find("InfectedService")
		if infected then
			for _, model in infected:getAlive() do
				local root = RigUtil.getRoot(model)
				if
					root
					and RigUtil.isAlive(model)
					and model:GetAttribute(Attributes.Infected.Burning) ~= true
				then
					-- Already burning bodies are skipped here rather than inside
					-- ignite, so a full horde standing in a pool is one table
					-- lookup each instead of a service call each.
					table.insert(snapshot.infected, model)
					snapshot.positions[model] = root.Position
				end
			end
		end
	end

	local survivors = Registry.find("SurvivorService")
	if survivors then
		for _, player in survivors:getAliveSurvivors() do
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				table.insert(snapshot.survivors, {
					player = player,
					character = character,
					position = root.Position,
				})
			end
		end
	end

	return snapshot
end

function ProjectileService:_stepZones(now: number, elapsed: number)
	if #self._fires == 0 and #self._zones == 0 then
		return
	end

	local bodies = self:_collectBodies()

	for index = #self._fires, 1, -1 do
		self:_stepFire(self._fires[index], index, now, elapsed, bodies)
	end
	for index = #self._zones, 1, -1 do
		self:_stepLureZone(self._zones[index], index, now)
	end
end

-- ════════════════════════════════════════════════════════════════════════════
--  Queries and teardown
-- ════════════════════════════════════════════════════════════════════════════

--[[ True while any fire pool covers a point. Anything that wants to keep an AI
     out of a molotov — or to decide a spawn point is a bad one — asks here
     rather than reaching into the pool list. ]]
function ProjectileService:isOnFire(position: Vector3): boolean
	if typeof(position) ~= "Vector3" then
		return false
	end
	for _, record in self._fires do
		if withinColumn(record.origin, position, record.radius, FIRE_HEIGHT) then
			return true
		end
	end
	return false
end

--[[ For the debug overlay and for a round teardown that wants to know whether
     anything is still burning. ]]
function ProjectileService:getActiveCounts(): { projectiles: number, fires: number, zones: number }
	return {
		projectiles = #self._live,
		fires = #self._fires,
		zones = #self._zones,
	}
end

--[[ Wipes everything in flight and everything burning, with no detonation. For
     a round reset: the next round must not begin inside the last one's fire. ]]
function ProjectileService:clearAll()
	for index = #self._live, 1, -1 do
		self:_retireProjectile(index)
	end
	for index = #self._fires, 1, -1 do
		self:_retireFire(index)
	end
	for index = #self._zones, 1, -1 do
		self:_retireLureZone(index)
	end
	table.clear(self._lastThrow)
end

function ProjectileService:destroy()
	self:clearAll()
	self._trove:destroy()
end

Registry.register("ProjectileService", ProjectileService)

return ProjectileService
